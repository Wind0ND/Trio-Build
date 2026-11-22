import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

@Suite("GlucoseStorage Tests", .serialized) struct GlucoseStorageTests: Injectable {
    @Injected() var storage: GlucoseStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        // Create test context
        // As we are only using this single test context to initialize our in-memory DeterminationStorage we need to perform the Unit Tests serialized
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        // Create assembler with test assembly
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext) // Add our test assembly last to override Storage
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    @Test("Storage is correctly initialized") func testStorageInitialization() {
        // Verify storage exists
        #expect(storage != nil, "GlucoseStorage should be injected")

        // Verify it's the correct type
        #expect(storage is BaseGlucoseStorage, "Storage should be of type BaseGlucoseStorage")
    }

    @Test("Store and retrieve glucose entries") func testStoreAndRetrieveGlucose() async throws {
        // Given
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 126)
        ]

        // When
        try await storage.storeGlucose(testGlucose)

        // Then verify stored entries
        let storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 126"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(storedEntries?.isEmpty == false, "Should have stored entries")
        #expect(storedEntries?.count == 1, "Should have exactly one entry")
        #expect(storedEntries?[0].glucose == 126, "Glucose value should match")
        #expect(storedEntries?[0].direction == "Flat", "Direction should match")
    }

    @Test("Confirmed storage excludes duplicate, overlapping and future samples") func confirmedWriteResults() async throws {
        let date = Date().addingTimeInterval(-300)
        let reading = BloodGlucose(sgv: 116, date: 1, dateString: date, noise: 3, glucose: 116)
        let stored = try await storage.storeGlucose([reading])
        let duplicate = try await storage.storeGlucose([reading])
        let backfill = try await storage.backfillGlucose([reading])
        let future = try await storage.storeGlucose([
            BloodGlucose(sgv: 140, date: 2, dateString: Date().addingTimeInterval(250), glucose: 140)
        ])
        #expect(stored.map(\.dateString) == [date])
        #expect(duplicate.isEmpty && backfill.isEmpty && future.isEmpty)
        let algorithm = try await storage.getGlucoseForAlgorithm(shouldSmoothGlucose: true, fetchHours: 1)
        #expect(algorithm.first?.noise == 3)
    }

    @Test("xDrip error 38 persists while an ordinary low reading keeps the clinical floor") func sensorErrorAndLow() async throws {
        let date = Date().addingTimeInterval(-600)
        let error = BloodGlucose(sgv: 38, date: 2, dateString: date, noise: 4, glucose: 38)
        let low = BloodGlucose(sgv: 38, date: 3, dateString: date.addingTimeInterval(300), glucose: 38)
        let storedError = try await storage.storeGlucose([error])
        let storedLow = try await storage.storeGlucose([low])
        #expect(storedError.first?.sgv == 38)
        #expect(storedLow.first?.sgv == 39)
    }

    @Test("Build 28 SQLite store migrates without losing real or ambiguous glucose history") func migrateBuild28Glucose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("history.sqlite")
        let directory = try #require(Bundle(for: CoreDataStack.self).url(forResource: "TrioCoreDataPersistentContainer", withExtension: "momd"))
        let oldModel = try #require(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("TrioCoreDataPersistentContainer.mom")))
        let before = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try before.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
        let oldContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = before
        let lastSimulation = Date(timeIntervalSince1970: 1_800_000_000)
        try oldContext.performAndWait {
            for (offset, manual, value) in [(-300, false, 155), (-60, true, 132), (300, false, 121)] {
                let row = NSEntityDescription.insertNewObject(forEntityName: "GlucoseStored", into: oldContext)
                row.setValue(lastSimulation.addingTimeInterval(Double(offset)), forKey: "date")
                row.setValue(value, forKey: "glucose")
                row.setValue(manual, forKey: "isManual")
            }
            try oldContext.save()
            oldContext.reset()
        }
        try before.remove(oldStore)
        let current = NSPersistentStoreCoordinator(managedObjectModel: CoreDataStack.managedObjectModel)
        let migrated = try current.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: [
            NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true
        ])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = current
        try context.performAndWait {
            let request = GlucoseStored.fetchRequest()
            let all = try context.fetch(request)
            #expect(all.map(\.glucose).sorted() == [121, 132, 155])
            #expect(all.allSatisfy { $0.isSimulated == nil && $0.noise == nil })
            request.predicate = BaseGlucoseStorage.provenancePredicate(simulated: false, legacyLastSimulation: lastSimulation)
            let usable = try context.fetch(request).map(\.glucose).sorted()
            #expect(usable == [121, 132])
        }
        try current.remove(migrated)
    }

    @Test("Physical glucose history excludes marked simulator data") func simulatorProvenance() async throws {
        let date = Date().addingTimeInterval(-600)
        let simulated = BloodGlucose(sgv: 220, date: 2, dateString: date, glucose: 220, transmitterID: "SIMULATOR")
        let actual = BloodGlucose(sgv: 98, date: 3, dateString: date, glucose: 98)
        try await storage.storeGlucose([simulated])
        let stored = try await storage.storeGlucose([actual])
        #expect(stored.count == 1)
        let algorithm = try await storage.getGlucoseForAlgorithm(shouldSmoothGlucose: false, fetchHours: 1)
        #expect(algorithm.map(\.sgv) == [98])
    }

    @Test("Malformed xDrip dates are ignored") func appGroupDate() {
        #expect(AppGroupSource.parseDate("/Date(1462404576000)/") == Date(timeIntervalSince1970: 1_462_404_576))
        #expect(AppGroupSource.parseDate("/Date(inf)/") == nil)
        #expect(AppGroupSource.parseDate("/Date(99999999999999999999)/") == nil)
    }

    @Test("Delete glucose entry") func testDeleteGlucose() async throws {
        // Given
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 140)
        ]
        try await storage.storeGlucose(testGlucose)

        // Get the stored entry's ObjectID
        let storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        guard let objectID = storedEntries?.first?.objectID else {
            throw TestError("Failed to get stored entry's ObjectID")
        }

        #expect(storedEntries.isNotNilNotEmpty == true, "Should have exactly one (test) entry")

        // When
        await storage.deleteGlucose(objectID)

        // Then verify deletion
        let remainingEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(remainingEntries?.isEmpty == true, "Should have no entries after deletion")

        // Finally verify that it stored a copy
        let archivedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: DeletedGlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as? [DeletedGlucoseStored]

        #expect(archivedEntries?.isEmpty == false, "Should have archived entries after deletion")
    }

    @Test("Get glucose not yet uploaded to Nightscout") func testGetGlucoseNotYetUploadedToNightscout() async throws {
        // Given
        let wholeSeconds = Int64(Date().timeIntervalSince1970)
        let date = Date(timeIntervalSince1970: TimeInterval(wholeSeconds) + 0.2038)
        let expectedMilliseconds = Decimal(wholeSeconds * 1000 + 204)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: date, glucose: 160)
        ]
        try await storage.storeGlucose(testGlucose)
        try await testContext.perform {
            let manualGlucose = GlucoseStored(context: testContext)
            manualGlucose.id = UUID()
            manualGlucose.date = date
            manualGlucose.glucose = 161
            manualGlucose.isManual = true
            manualGlucose.isUploadedToNS = false
            manualGlucose.isUploadedToHealth = false
            manualGlucose.isUploadedToTidepool = false
            try testContext.save()
        }

        // When
        let notUploadedEntries = try await storage.getGlucoseNotYetUploadedToNightscout()

        // Then
        let sensorEntry = notUploadedEntries.first { $0.sgv == 160 }
        #expect(sensorEntry != nil, "Should have the sensor entry not uploaded to NS")
        #expect(sensorEntry?.date == expectedMilliseconds, "Sensor date should use integer milliseconds")
        #expect(sensorEntry?.dateString == date, "Sensor date fields should represent the same instant")

        let manualEntry = notUploadedEntries.first { $0.mbg == 161 }
        #expect(manualEntry != nil, "Should have the manual entry not uploaded to NS")
        #expect(manualEntry?.date == expectedMilliseconds, "Manual date should use integer milliseconds")
        #expect(manualEntry?.dateString == date, "Manual date fields should represent the same instant")
        #expect(manualEntry?.type == "mbg", "Manual entry type should remain unchanged")
    }

    @Test("Sub-39 glucose is clamped to 39 on storeGlucose") func testStoreGlucoseClampsBelowMinimum() async throws {
        // Given a CGM reading below the 39 mg/dL floor (e.g. LibreTransmitter delivering 23)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 23)
        ]

        // When
        try await storage.storeGlucose(testGlucose)

        // Then the stored row should be clamped to 39, not 23
        let clampedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 39"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(clampedEntries?.count == 1, "Sub-39 glucose should be clamped and stored as 39")

        let rawEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 23"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(rawEntries?.isEmpty == true, "Raw sub-39 value must not be persisted")
    }

    @Test("Sub-39 glucose is clamped to 39 on backfillGlucose") func testBackfillGlucoseClampsBelowMinimum() async throws {
        // Given a backfilled CGM reading below the 39 mg/dL floor
        let backfillDate = Date().addingTimeInterval(-30 * 60)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 456, dateString: backfillDate, glucose: 28)
        ]

        // When
        try await storage.backfillGlucose(testGlucose)

        // Then the backfilled row should be clamped to 39
        let clampedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 39"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(clampedEntries?.count == 1, "Sub-39 backfilled glucose should be clamped and stored as 39")
    }

    @Test("Manual glucose does not advance CGM sync dates") func testSyncDateIgnoresManualGlucose() async throws {
        // Given a CGM reading followed by a manual entry 3 minutes later
        let cgmDate = Date().addingTimeInterval(-5 * 60)
        try await storage.storeGlucose([
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 789, dateString: cgmDate, glucose: 110)
        ])
        try await insertManualGlucose(112, at: cgmDate.addingTimeInterval(3 * 60))

        // When
        let syncDate = storage.syncDate()

        // Then the next CGM reading is not filtered as too frequent
        #expect(abs(syncDate.timeIntervalSince(cgmDate)) < 1, "syncDate should be the last CGM reading")
        let lastDate = try #require(storage.lastGlucoseDate())
        #expect(abs(lastDate.timeIntervalSince(cgmDate)) < 1, "lastGlucoseDate should be the last CGM reading")
        let next = BloodGlucose(direction: .flat, date: 790, dateString: cgmDate.addingTimeInterval(5 * 60), glucose: 108)
        #expect(storage.filterTooFrequentGlucose([next], at: syncDate).count == 1)
    }

    @Test("Backfill is not deduplicated against manual glucose") func testBackfillIgnoresManualGlucose() async throws {
        // Given a manual entry 1 minute after a missed CGM reading
        let backfillDate = Date().addingTimeInterval(-20 * 60)
        try await insertManualGlucose(150, at: backfillDate.addingTimeInterval(60))

        // When
        try await storage.backfillGlucose([
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 791, dateString: backfillDate, glucose: 147)
        ])

        // Then the backfilled CGM reading is stored
        let backfilled = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 147 AND isManual == NO"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        #expect(backfilled?.count == 1, "Backfilled CGM reading near a manual entry should be stored")
    }

    private func insertManualGlucose(_ glucose: Int16, at date: Date) async throws {
        try await testContext.perform {
            let manualGlucose = GlucoseStored(context: testContext)
            manualGlucose.id = UUID()
            manualGlucose.date = date
            manualGlucose.glucose = glucose
            manualGlucose.isManual = true
            try testContext.save()
        }
    }

    @Test(
        "Test glucose alarms",
        .enabled(if: false, "Flaky test, disabled while investigating")
    ) func testGlucoseAlarms() async throws {
        // Given
        let lowGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 55)
        ]
        let highGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 271)
        ]
        let normalGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 100)
        ]

        // When - Test low glucose
        try await storage.storeGlucose(lowGlucose)
        var storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 55"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        // Then
        #expect(storedEntries?.first?.glucose == 55, "Low glucose value should match")
        #expect(storage.alarm == .low, "Should trigger low glucose alarm") // default low limit is 72 mg/dL

        // When - Test high glucose
        try await storage.storeGlucose(highGlucose)
        storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 271"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        // Then
        #expect(storedEntries?.first?.glucose == 271, "High glucose value should match")
        #expect(storage.alarm == .high, "Should trigger high glucose alarm") // default high limit is 270 mg/dL

        // When - Test normal glucose
        try await storage.storeGlucose(normalGlucose)
        storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 100"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]

        // Then
        #expect(storedEntries?.first?.glucose == 100, "Normal glucose value should match")
        #expect(storage.alarm == nil, "Should not trigger any alarm")
    }

    /* Commenting out while we don't have getGlucoseStatus defined
     @Test("getGlucoseStatus returns correct deltas for 0/5/15/30m readings") func testGetGlucoseStatusFourPoints() async throws {
         let now = Date()
         // Prepare 4 readings: at 0, 5, 15, and 30 minutes ago
         let specs: [(offset: TimeInterval, value: Int)] = [
             (0, 100), // now
             (5 * 60, 110), // 5m ago
             (15 * 60, 120), // 15m ago
             (30 * 60, 130) // 30m ago
         ]

         // Insert them into CoreData so that our fetch predicate picks them up
         for (offset, value) in specs {
             await testContext.perform {
                 let glucoseToStore = GlucoseStored(context: testContext)
                 glucoseToStore.id = UUID()
                 glucoseToStore.date = now.addingTimeInterval(-offset)
                 glucoseToStore.glucose = Int16(value)
             }
         }
         try testContext.save()

         // Call the method under test
         let status = try await storage.getGlucoseStatus()
         #expect(status != nil, "Expected non‐nil status")

         // “Now” glucose is the 0m reading
         #expect(status!.glucose == 100)

         // lastDelta: only the 5m point: (100–110)/5*5 = –10
         #expect(status!.delta == -10)

         // shortAvgDelta: average of 5m and 15m windows:
         //   5m window:   (100–110)/5*5   = –10
         //   15m window: (100–120)/15*5 ≈ –6.6667 → –6.67
         //   avg ≈ (–10 + –6.67)/2 = –8.333… → rounded to –8.33
         #expect(status!.shortAvgDelta == -8.33)

         // longAvgDelta: only the 30m window: (100–130)/30*5 = –5
         #expect(status!.longAvgDelta == -5)
     }*/
}

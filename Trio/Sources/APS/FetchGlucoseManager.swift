import BackgroundKeepAliveKit
import Combine
import CoreData
import Foundation
import LoopKit
import LoopKitUI
import MockKit
import SwiftDate
import Swinject
import UIKit

protocol FetchGlucoseManager: SourceInfoProvider {
    func updateGlucoseSource(cgmGlucoseSourceType: CGMType, cgmGlucosePluginId: String, newManager: CGMManagerUI?)
    func deleteGlucoseSource() async
    func removeCalibrations()
    func newGlucoseFromCgmManager(newGlucose: [BloodGlucose], revision: UUID, completion: @escaping (Bool) -> Void)
    func requestRecovery(completion: @escaping @Sendable (Bool) -> Void)
    func requestRecovery(isAuthorized: @escaping @Sendable () -> Bool, completion: @escaping @Sendable (Bool) -> Void)
    var recoverySourceRevision: UUID { get }
    var freshnessSourceID: String { get }
    /// Notes to Nightscout a sensor state without reliable glucose, once per
    /// state; see `CGMSensorStateLog`. Call on every reading.
    func reportCGMSensorObservation(_ observation: CGMSensorObservation)
    func startCGMSensorSession(startedAt: Date)
    var glucoseSource: GlucoseSource? { get }
    var cgmManager: CGMManagerUI? { get }
    var cgmGlucoseSourceType: CGMType { get set }
    var cgmGlucosePluginId: String { get }
    var settingsManager: SettingsManager! { get }
    var shouldSyncToRemoteService: Bool { get }
    var cgmDisplayState: CurrentValueSubject<CgmDisplayState?, Never> { get }
    var cgmProgressHighlight: CurrentValueSubject<DeviceLifecycleProgress?, Never> { get }
    /// Routes CGMManager-issued alerts (sensor failure, signal loss, expiry,
    /// etc.) into the unified `TrioAlertManager` pipeline. Read by
    /// `PluginSource.issueAlert` / `retractAlert`.
    var trioAlertManager: TrioAlertManager! { get }
}

extension FetchGlucoseManager {
    var freshnessSourceID: String { cgmGlucoseSourceType.rawValue }
    var recoverySourceRevision: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
    func requestRecovery(isAuthorized: @escaping @Sendable () -> Bool, completion: @escaping @Sendable (Bool) -> Void) {
        guard isAuthorized() else { completion(false); return }
        requestRecovery(completion: completion)
    }
    func requestRecovery(completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
    func updateGlucoseSource(cgmGlucoseSourceType: CGMType, cgmGlucosePluginId: String) {
        updateGlucoseSource(cgmGlucoseSourceType: cgmGlucoseSourceType, cgmGlucosePluginId: cgmGlucosePluginId, newManager: nil)
    }
}

final class BaseFetchGlucoseManager: FetchGlucoseManager, Injectable {
    private let freshnessIdentity = KeepAliveSourceIdentity()
    var freshnessSourceID: String { freshnessIdentity.id }
    private typealias SourceResult = (glucose: [BloodGlucose], owner: String, revision: UUID)
    var recoverySourceRevision: UUID { deviceDataManager.glucoseSourceRevision }
    private let processQueue = DispatchQueue(label: "BaseGlucoseManager.processQueue")

    @Injected() var broadcaster: Broadcaster!
    @Injected() var glucoseStorage: GlucoseStorage!
    @Injected() var nightscoutManager: NightscoutManager!
    @Injected() var settingsManager: SettingsManager!
    @Injected() var healthKitManager: HealthKitManager!
    @Injected() var deviceDataManager: DeviceDataManager!
    @Injected() var pluginCGMManager: PluginManager!
    @Injected() var calibrationService: CalibrationService!
    @Injected() var trioAlertManager: TrioAlertManager!
    @Injected() private var deviceLogStore: DeviceLogStore!

    /// Guarded by `sensorStateLock`.
    @Persisted(key: "cgmSensorStateLog") private var sensorStateLog = CGMSensorStateLog()
    private let sensorStateLock = NSRecursiveLock()

    private var lifetime = Lifetime()
    private let timer = DispatchTimer(timeInterval: 1.minutes.timeInterval)
    var cgmGlucoseSourceType: CGMType = .none
    var cgmGlucosePluginId: String = ""
    var cgmManager: CGMManagerUI? {
        didSet {
            rawCGMManager = cgmManager?.rawValue
            UserDefaults.standard.clearLegacyCGMManagerRawValue()
        }
    }

    @PersistedProperty(key: "CGMManagerState") var rawCGMManager: CGMManager.RawValue?

    private lazy var simulatorSource = GlucoseSimulatorSource()

    /// Enforce mutual exclusion on calls to glucoseStoreAndHeartDecision
    private let glucoseStoreAndHeartLock = DispatchSemaphore(value: 1)

    var shouldSyncToRemoteService: Bool {
        guard let cgmManager = cgmManager else {
            return true
        }
        return cgmManager.shouldSyncToRemoteService
    }

    var shouldSmoothGlucose: Bool = false

    init(resolver: Resolver) {
        injectServices(resolver)
        // init at the start of the app
        cgmGlucoseSourceType = settingsManager.settings.cgm
        cgmGlucosePluginId = settingsManager.settings.cgmPluginIdentifier
        // load cgmManager
        updateGlucoseSource(
            cgmGlucoseSourceType: settingsManager.settings.cgm,
            cgmGlucosePluginId: settingsManager.settings.cgmPluginIdentifier
        )
        shouldSmoothGlucose = settingsManager.settings.smoothGlucose
        subscribe()
    }

    /// The function used to start the timer sync - Function of the variable defined in config
    private func subscribe() {
        timer.publisher
            .receive(on: processQueue)
            .flatMap { [self] _ -> AnyPublisher<SourceResult, Never> in
                if let glucoseSource = self.glucoseSource {
                    let owner = freshnessSourceID
                    let revision = recoverySourceRevision
                    return glucoseSource.fetch(self.timer).map { (glucose: $0, owner: owner, revision: revision) }.eraseToAnyPublisher()
                } else {
                    return Empty(completeImmediately: false).eraseToAnyPublisher()
                }
            }
            .sink { result in
                let glucose = result.glucose
                debug(.cgm, "Glucose source returned \(glucose.count) readings")
                Publishers.CombineLatest(
                    Just(glucose),
                    Just(self.glucoseStorage.syncDate())
                )
                .eraseToAnyPublisher()
                .sink { newGlucose, syncDate in
                    self.glucoseStoreAndHeartLock.wait()
                    Task {
                        do {
                            try await self.glucoseStoreAndHeartDecision(
                                syncDate: syncDate,
                                glucose: newGlucose,
                                isAuthorized: { self.recoverySourceRevision == result.revision }, sourceID: result.owner
                            )
                        } catch {
                            warning(.cgm, "Storing glucose failed", error: error)
                        }
                        self.glucoseStoreAndHeartLock.signal()
                    }
                }
                .store(in: &self.lifetime)
            }
            .store(in: &lifetime)
        timer.fire()
        timer.resume()

        broadcaster.register(SettingsObserver.self, observer: self)
    }

    /// Uses the same source and serialized storage path for plugins, xDrip and Nightscout.
    func requestRecovery(completion: @escaping @Sendable (Bool) -> Void) {
        requestRecovery(isAuthorized: { true }, completion: completion)
    }

    func requestRecovery(isAuthorized: @escaping @Sendable () -> Bool, completion: @escaping @Sendable (Bool) -> Void) {
        let revision = recoverySourceRevision
        let owner = freshnessSourceID
        let current: @Sendable () -> Bool = { [weak self] in
            isAuthorized() && self?.recoverySourceRevision == revision
        }
        processQueue.async { [weak self] in
            guard let self, current(), let source = self.glucoseSource else { completion(false); return }
            source.fetch(nil)
                .prefix(1)
                .timeout(15, scheduler: self.processQueue)
                .replaceEmpty(with: [])
                .receive(on: self.processQueue)
                .sink { glucose in
                    self.glucoseStoreAndHeartLock.wait()
                    let syncDate = self.glucoseStorage.syncDate()
                    Task {
                        defer { self.glucoseStoreAndHeartLock.signal() }
                        guard current() else { completion(false); return }
                        do {
                            let stored = try await self.glucoseStoreAndHeartDecision(syncDate: syncDate, glucose: glucose, isAuthorized: current, sourceID: owner)
                            completion(current() && stored)
                        } catch {
                            warning(.cgm, "Recovery storage failed", error: error)
                            completion(false)
                        }
                    }
                }
                .store(in: &self.lifetime)
        }
    }

    /// Store new glucose readings from the CGM manager
    ///
    /// This function enables plugin CGM managers to send new glucose readings directly
    /// to the FetchGlucoseManager, bypassing the Combine pipeline. By bypassing the
    /// Combine pipeline CGM managers can send backfill glucose readings, which come
    /// right after a new glucose reading, typically.
    func newGlucoseFromCgmManager(newGlucose: [BloodGlucose], revision: UUID, completion: @escaping (Bool) -> Void) {
        guard revision == recoverySourceRevision else { completion(false); return }
        let owner = freshnessSourceID
        glucoseStoreAndHeartLock.wait()
        let syncDate = glucoseStorage.syncDate()
        Task {
            do {
                try await glucoseStoreAndHeartDecision(
                    syncDate: syncDate,
                    glucose: newGlucose,
                    isAuthorized: { self.recoverySourceRevision == revision }, sourceID: owner
                )
                completion(recoverySourceRevision == revision)
            } catch {
                warning(.cgm, "Storing glucose from the CGM failed", error: error)
                completion(false)
            }
            glucoseStoreAndHeartLock.signal()
        }
    }

    let cgmDisplayState = CurrentValueSubject<CgmDisplayState?, Never>(nil)
    let cgmProgressHighlight = CurrentValueSubject<DeviceLifecycleProgress?, Never>(nil)
    private var cgmStatusSubscriptions = Set<AnyCancellable>()

    var glucoseSource: GlucoseSource? {
        didSet {
            deviceDataManager.glucoseSourceRevision = UUID()
            // Drop prior subscriptions so source swaps don't dupe emissions.
            cgmStatusSubscriptions.removeAll()
            cgmDisplayState.value = glucoseSource?.cgmDisplayState.value
            cgmProgressHighlight.value = glucoseSource?.cgmProgressHighlight.value
            guard let glucoseSource else { return }
            glucoseSource.cgmDisplayState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in self?.cgmDisplayState.value = state }
                .store(in: &cgmStatusSubscriptions)
            glucoseSource.cgmProgressHighlight
                .receive(on: DispatchQueue.main)
                .sink { [weak self] progress in self?.cgmProgressHighlight.value = progress }
                .store(in: &cgmStatusSubscriptions)
        }
    }

    func removeCalibrations() {
        calibrationService.removeAllCalibrations()
    }

    func reportCGMSensorObservation(_ observation: CGMSensorObservation) {
        let settings = settingsManager.settings
        guard settings.isUploadEnabled, settings.uploadCGMSensorStates else { return }
        let pending = sensorStateLock.perform { sensorStateLog.observe(observation) }
        guard let pending else { return }

        Task {
            let note = "CGM: " + pending
            if await nightscoutManager.uploadNoteTreatment(note: note) {
                debug(.nightscout, "CGM sensor state uploaded: \(note)")
            } else {
                self.sensorStateLock.perform { self.sensorStateLog.uploadFailed(pending) }
                warning(.nightscout, "CGM sensor state upload failed, will retry: \(note)")
            }
        }
    }

    func startCGMSensorSession(startedAt: Date) {
        let changed = sensorStateLock.perform {
            guard sensorStateLog.sensorSessionStart != startedAt else { return false }
            sensorStateLog.startSensor(startedAt: startedAt)
            return true
        }
        if changed { removeCalibrations() }
    }

    @MainActor func deleteGlucoseSource() async {
        cgmManager = nil
        glucoseSource = nil
        settingsManager.settings.cgm = cgmDefaultModel.type
        settingsManager.settings.cgmPluginIdentifier = cgmDefaultModel.id
        updateGlucoseSource(
            cgmGlucoseSourceType: cgmDefaultModel.type,
            cgmGlucosePluginId: cgmDefaultModel.id
        )
    }

    func saveConfigManager() {
        guard let cgmM = cgmManager else {
            return
        }
        // save the config in rawCGMManager
        rawCGMManager = cgmM.rawValue

        // sync with upload glucose
        settingsManager.settings.uploadGlucose = cgmM.shouldSyncToRemoteService
    }

    private func updateManagerUnits(_ manager: CGMManagerUI?) {
        let units = settingsManager.settings.units
        let managerName = cgmManager.map { "\(type(of: $0))" } ?? "nil"
        let loopkitUnits: LoopUnit = units == .mgdL ? .milligramsPerDeciliter : .millimolesPerLiter
        debug(.cgm, "\(managerName) units set to \(loopkitUnits.unitString)")
        manager?.unitDidChange(to: loopkitUnits)
    }

    func updateGlucoseSource(cgmGlucoseSourceType: CGMType, cgmGlucosePluginId: String, newManager: CGMManagerUI?) {
        let replacing = KeepAliveSourceIdentity.isReplacement(
            current: cgmManager.map { $0 as AnyObject }, proposed: newManager.map { $0 as AnyObject }
        )
        freshnessIdentity.select(cgmGlucoseSourceType.rawValue + "/" + cgmGlucosePluginId, replacing: replacing)
        // if changed, remove all calibrations
        if self.cgmGlucoseSourceType != cgmGlucoseSourceType || self.cgmGlucosePluginId != cgmGlucosePluginId {
            info(
                .cgm,
                "Glucose source changed to \(cgmGlucoseSourceType.rawValue)\(cgmGlucosePluginId.isEmpty ? "" : ", \(cgmGlucosePluginId)")"
            )
            removeCalibrations()
            cgmManager = nil
            glucoseSource = nil
        }

        self.cgmGlucoseSourceType = cgmGlucoseSourceType
        self.cgmGlucosePluginId = cgmGlucosePluginId

        // if not plugin, manager is not changed and stay with the "old" value if the user come back to previous cgmtype
        // if plugin, if the same pluginID, no change required because the manager is available
        // if plugin, if not the same pluginID, need to reset the cgmManager
        // if plugin and newManager provides, update cgmManager
        if let manager = newManager {
            if replacing {
                glucoseSource = nil
                removeCalibrations()
            }
            cgmManager = manager
        } else if self.cgmGlucoseSourceType == .plugin, cgmManager == nil, let rawCGMManager = rawCGMManager {
            cgmManager = cgmManagerFromRawValue(rawCGMManager)
            updateManagerUnits(cgmManager)

        } else {
            saveConfigManager()
        }

        if glucoseSource == nil {
            switch self.cgmGlucoseSourceType {
            case .none:
                glucoseSource = nil
            case .xdrip:
                glucoseSource = AppGroupSource(from: "xDrip", cgmType: .xdrip)
            case .nightscout:
                glucoseSource = nightscoutManager
            case .simulator:
                glucoseSource = simulatorSource
            case .plugin:
                glucoseSource = PluginSource(
                    glucoseStorage: glucoseStorage,
                    glucoseManager: self,
                    deviceLogStore: deviceLogStore
                )
            }
        }

        // Only an active plugin CGM with its own BLE connection can wake the app; otherwise the pump must heartbeat
        let cgmProvidesHeartbeat = cgmGlucoseSourceType == .plugin && (cgmManager?.providesBLEHeartbeat ?? false)
        deviceDataManager.updateCGMHeartbeatCapability(providesBLEHeartbeat: cgmProvidesHeartbeat)
    }

    /// Upload cgmManager from raw value
    func cgmManagerFromRawValue(_ rawValue: [String: Any]) -> CGMManagerUI? {
        guard let rawState = rawValue["state"] as? CGMManager.RawStateValue,
              let Manager = pluginCGMManager.getCGMManagerTypeByIdentifier(cgmGlucosePluginId)
        else {
            return nil
        }
        return Manager.init(rawState: rawState)
    }

    @discardableResult private func glucoseStoreAndHeartDecision(
        syncDate: Date, glucose: [BloodGlucose], isAuthorized: @Sendable () -> Bool = { true }, sourceID: String? = nil
    ) async throws -> Bool {
        guard isAuthorized() else { return false }
        if glucose.contains(where: \.isSimulated),
           let pump = deviceDataManager.pumpManager, !(pump is MockPumpManager) { return false }
        let newGlucose = overcalibrate(entries: glucose.filter { $0.sgv != nil })
        var backgroundTaskID = startBackgroundTask(withName: "Glucose Store and Heartbeat Decision")
        defer { endBackgroundTaskSafely(&backgroundTaskID, taskName: "Glucose Store and Heartbeat Decision") }

        let calibrations = glucose.filter { $0.mbg != nil }
        if !calibrations.isEmpty {
            guard isAuthorized() else { return false }
            try await glucoseStorage.storeGlucose(calibrations)
        }

        let backfill = newGlucose.filter { $0.dateString <= syncDate }
        var storedBackfill: [BloodGlucose] = []
        if !backfill.isEmpty {
            guard isAuthorized() else { return false }
            storedBackfill = try await glucoseStorage.backfillGlucose(backfill)
            guard isAuthorized() else { return false }
            reportAcceptedSamples(storedBackfill, sourceID: sourceID)
        }

        let fresh = glucoseStorage.filterTooFrequentGlucose(newGlucose.filter { $0.dateString > syncDate }, at: syncDate)
        guard !fresh.isEmpty, isAuthorized() else { return storedBackfill.contains(where: Self.isValidStoredSample) }
        let stored = try await glucoseStorage.storeGlucose(fresh)
        guard !stored.isEmpty, isAuthorized() else { return storedBackfill.contains(where: Self.isValidStoredSample) }
        reportAcceptedSamples(stored, sourceID: sourceID)
        if settingsManager.settings.smoothGlucose {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "exponentialSmoothingGlucose"
            await exponentialSmoothingGlucose(context: context)
        }

        guard isAuthorized() else { return false }
        deviceDataManager.updatePumpBLEHeartbeat(
            lastCGMReadingDate: stored.map(\.dateString).max(),
            expectedCGMReadingInterval: cgmManager?.expectedGlucoseSampleInterval
        )
        deviceDataManager.heartbeat(date: Date())
        TelemetryClient.shared.checkAndSendIfOverdueInBackground()
        return (stored + storedBackfill).contains(where: Self.isValidStoredSample)
    }

    private static func isValidStoredSample(_ sample: BloodGlucose) -> Bool {
        sample.mbg == nil && (sample.glucose ?? 0) > 0 && (sample.noise ?? 0) < 3 && sample.dateString <= Date()
    }

    func sourceInfo() -> [String: Any]? {
        glucoseSource?.sourceInfo()
    }

    private func reportAcceptedSamples(_ samples: [BloodGlucose], sourceID: String?) {
        guard let sourceID, sourceID == freshnessSourceID,
              let date = samples.filter(Self.isValidStoredSample)
                .map(\.dateString).max() else { return }
        BackgroundKeepAlive.reportStoredSample(at: date, sourceID: sourceID)
    }

    private func overcalibrate(entries: [BloodGlucose]) -> [BloodGlucose] {
        // overcalibrate
        var overcalibration: ((Int) -> (Double))?

        if let cal = calibrationService {
            overcalibration = cal.calibrate
        }

        if let overcalibration = overcalibration {
            return entries.map { entry in
                var entry = entry
                guard entry.glucose != nil, (entry.noise ?? 0) < 3 else { return entry }
                entry.glucose = Int(overcalibration(entry.glucose!))
                entry.sgv = Int(overcalibration(entry.sgv!))
                return entry
            }
        } else {
            return entries
        }
    }
}

extension FetchGlucoseManager {
    /// Dispatches given `functionToInvoke` to the CGM manager's queue (if any).
    func performOnCGMManagerQueue(_ functionToInvoke: @escaping () -> Void) {
        // If a CGM manager exists and it defines a delegate queue, use it
        if let cgmManager = self.cgmManager,
           let managerQueue = cgmManager.delegateQueue
        {
            managerQueue.async {
                functionToInvoke()
            }
        } else {
            // If there's no cgmManager or no queue, just run the block immediately
            // This possibly executes `functionToInvoke` on main thread
            functionToInvoke()
        }
    }
}

extension CGMManager {
    typealias RawValue = [String: Any]

    var rawValue: [String: Any] {
        [
            "managerIdentifier": pluginIdentifier,
            "state": rawState
        ]
    }
}

extension BaseFetchGlucoseManager: SettingsObserver {
    /// Smooth glucose data when smoothing is turned on.
    func settingsDidChange(_: TrioSettings) {
        Task { @MainActor in BackgroundKeepAlive.shared.settingsChanged() }
        let smoothingWasEnabled = shouldSmoothGlucose
        let smoothingIsEnabled = settingsManager.settings.smoothGlucose
        shouldSmoothGlucose = smoothingIsEnabled

        guard smoothingIsEnabled, !smoothingWasEnabled else { return }

        processQueue.async { [weak self] in
            guard let self else { return }

            self.glucoseStoreAndHeartLock.wait()
            Task {
                let context = CoreDataStack.shared.newTaskContext()
                context.name = "exponentialSmoothingGlucose"
                await self.exponentialSmoothingGlucose(context: context)
                self.glucoseStoreAndHeartLock.signal()
            }
        }
    }
}

extension BaseFetchGlucoseManager {
    func fetchGlucose(context: NSManagedObjectContext) async throws -> [NSManagedObjectID] {
        // Compound predicate: time window + non-manual + valid date
        let timePredicate = NSPredicate.predicateForOneDayAgoInMinutes
        let manualPredicate = NSPredicate.cgmGlucose
        let datePredicate = NSPredicate(format: "date != nil")

        let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            timePredicate,
            manualPredicate,
            datePredicate,
            BaseGlucoseStorage.provenancePredicate(simulated: settingsManager.settings.cgm == .simulator)
        ])

        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            // Predicate must cover at least the full glucose horizon used by downstream algorithm consumers.
            // If autosens / oref / smoothing logic ever starts looking back further (e.g. 36h),
            // this fetch window must be expanded accordingly.
            // Fetch descending (newest first) so the limit always keeps the most recent 350 readings.
            // Reversed before return so callers receive oldest-first (chronological) order.
            predicate: compoundPredicate,
            key: "date",
            ascending: false,
            fetchLimit: 350
        )

        guard let glucoseArray = results as? [GlucoseStored] else {
            throw CoreDataError.fetchError(function: #function, file: #file)
        }

        return Array(glucoseArray.map(\.objectID).reversed())
    }

    /// CoreData-friendly AAPS exponential smoothing + storage.
    /// - Important: Only stores `smoothedGlucose`. UI/alerts should still use `glucose`.
    ///
    func exponentialSmoothingGlucose(context: NSManagedObjectContext) async {
        let startTime = Date()

        do {
            // get objectIDs
            let objectIDs = try await fetchGlucose(context: context)

            try await context.perform {
                // Load managed objects from object IDs
                // Filtering (isManual, date) already done at DB level in fetchGlucose
                let glucoseReadings = objectIDs.compactMap {
                    context.object(with: $0) as? GlucoseStored
                }

                guard !glucoseReadings.isEmpty else { return }

                // Static method call to avoid self-capture
                Self.applyExponentialSmoothingAndStore(
                    glucoseReadings: glucoseReadings,
                    minimumWindowSize: 4,
                    maximumAllowedGapMinutes: 12,
                    xDripErrorGlucose: 38,
                    minimumSmoothedGlucose: 39,
                    firstOrderWeight: 0.4,
                    firstOrderAlpha: 0.5,
                    secondOrderAlpha: 0.4,
                    secondOrderBeta: 1.0
                )

                try context.save()
            }

            let duration = Date().timeIntervalSince(startTime)
            debug(.cgm, String(format: "Glucose smoothing took %.3f s", duration))
        } catch {
            warning(.cgm, "Glucose smoothing failed", error: error)
        }
    }

    private static func applyExponentialSmoothingAndStore(
        glucoseReadings data: [GlucoseStored],
        minimumWindowSize: Int,
        maximumAllowedGapMinutes: Int,
        xDripErrorGlucose: Int,
        minimumSmoothedGlucose: Decimal,
        firstOrderWeight: Decimal,
        firstOrderAlpha: Decimal,
        secondOrderAlpha: Decimal,
        secondOrderBeta: Decimal
    ) {
        guard !data.isEmpty else { return }

        // Determine the size of the valid most-recent smoothing window.
        // We walk adjacent pairs from newest -> oldest to preserve the same window semantics
        // as the original implementation, but avoid manual reverse indexing.
        var validWindowCount = max(data.count - 1, 0)

        for (recentOffset, pair) in zip(data.dropFirst().reversed(), data.dropLast().reversed()).enumerated() {
            let (newer, older) = pair

            guard let newerDate = newer.date, let olderDate = older.date else { continue }

            let gapSeconds = newerDate.timeIntervalSince(olderDate)
            let gapMinutesRounded = Int((gapSeconds / 60.0).rounded())

            if gapMinutesRounded >= maximumAllowedGapMinutes {
                validWindowCount = recentOffset + 1 // include the more recent reading
                break
            }

            // Ported from AAPS: 38 mg/dL may represent an xDrip error state.
            if Int(newer.glucose) == xDripErrorGlucose || (newer.noise?.intValue ?? 0) >= 3 {
                validWindowCount = recentOffset // exclude this 38 value
                break
            }
        }

        // Not enough recent contiguous readings to smooth (e.g. after CGM gap).
        // IMPORTANT: Only apply fallback to the recent window, not all data.
        // Otherwise a recent gap would overwrite historical smoothed values.
        guard validWindowCount >= minimumWindowSize else {
            let recentWindow = data.suffix(validWindowCount)

            for object in recentWindow {
                let raw = Decimal(Int(object.glucose))
                object.smoothedGlucose = max(raw, minimumSmoothedGlucose) as NSDecimalNumber
            }

            return
        }

        // Restrict smoothing to the valid most-recent window, still in chronological order.
        let validWindow = data.suffix(validWindowCount)

        guard let oldest = validWindow.first else { return }

        // ---- 1st order smoothing ----
        var firstOrderSmoothed: [Decimal] = []
        firstOrderSmoothed.reserveCapacity(validWindow.count)

        var firstOrderCurrent = Decimal(Int(oldest.glucose))
        firstOrderSmoothed.append(firstOrderCurrent)

        for sample in validWindow.dropFirst() {
            let raw = Decimal(Int(sample.glucose))
            firstOrderCurrent = firstOrderCurrent + firstOrderAlpha * (raw - firstOrderCurrent)
            firstOrderSmoothed.append(firstOrderCurrent)
        }

        // ---- 2nd order smoothing ----
        let secondOrderInput = Array(validWindow)
        guard secondOrderInput.count >= 2 else { return }

        var secondOrderSmoothed: [Decimal] = []
        secondOrderSmoothed.reserveCapacity(secondOrderInput.count)

        var secondOrderDeltas: [Decimal] = []
        secondOrderDeltas.reserveCapacity(secondOrderInput.count)

        var previousSecondOrderSmoothed = Decimal(Int(secondOrderInput[0].glucose))
        var previousSecondOrderDelta =
            Decimal(Int(secondOrderInput[1].glucose) - Int(secondOrderInput[0].glucose))

        secondOrderSmoothed.append(previousSecondOrderSmoothed)
        secondOrderDeltas.append(previousSecondOrderDelta)

        for sample in secondOrderInput.dropFirst() {
            let raw = Decimal(Int(sample.glucose))

            let nextSmoothed =
                secondOrderAlpha * raw
                    + (1 - secondOrderAlpha) * (previousSecondOrderSmoothed + previousSecondOrderDelta)

            let nextDelta =
                secondOrderBeta * (nextSmoothed - previousSecondOrderSmoothed)
                    + (1 - secondOrderBeta) * previousSecondOrderDelta

            previousSecondOrderSmoothed = nextSmoothed
            previousSecondOrderDelta = nextDelta

            secondOrderSmoothed.append(nextSmoothed)
            secondOrderDeltas.append(nextDelta)
        }

        // ---- Weighted blend ----
        let blended = zip(firstOrderSmoothed, secondOrderSmoothed).map { firstOrder, secondOrder in
            firstOrderWeight * firstOrder + (1 - firstOrderWeight) * secondOrder
        }

        // Apply to the most recent valid-window readings.
        for (object, blendedValue) in zip(validWindow, blended) {
            let rounded = blendedValue.rounded(toPlaces: 0) // nearest integer, ties away from zero
            let clamped = max(rounded, minimumSmoothedGlucose)
            object.smoothedGlucose = clamped as NSDecimalNumber
        }
    }
}

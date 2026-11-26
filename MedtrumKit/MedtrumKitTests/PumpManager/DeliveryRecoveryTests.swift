@testable import MedtrumKit
import LoopKit
import XCTest
import MedtrumLifecycleKit

final class DeliveryRecoveryTests: XCTestCase {
    func testUnexecutedAutomaticShortConsumesNativeBaselineProofAndRestoresInterval() throws {
        let (manager, _) = fixture(expired: false)
        let request = try XCTUnwrap(manager.state.pendingTempBasal)
        let prior = BasalData(type: .STANDARD, sequence: 907, patchId: 256,
            startTime: request.startDate.addingTimeInterval(-300), rate: 0.8, delivery: 0)
        let baseline = MedtrumBasalRecoveryBaseline(segment: prior, sessionID: manager.state.patchId,
            sessionStartedAt: manager.state.patchActivatedAt!, observedAt: request.startDate.addingTimeInterval(-1))
        manager.state.basalRecoveryCheckpoint = MedtrumBasalRecoveryCheckpoint(baseline: baseline,
            requestID: request.decisionId, requestStart: request.startDate, requestEnd: request.estimatedEndDate,
            requestRate: request.value)
        var intent = try XCTUnwrap(MedtrumShortTempBasal(sessionID: manager.state.patchId,
            sessionStartedAt: manager.state.patchActivatedAt!, commandID: request.decisionId!,
            rate: request.value, minutes: 1, requestedAt: request.startDate, automatic: true))
        intent.pulseBudget = 0.1
        intent.previousPulseAt = request.startDate.addingTimeInterval(-600)
        manager.state.shortTempBasal = intent
        manager.state.lastBasalPulseAt = request.startDate
        manager.state.lastBasalPulseSessionID = intent.sessionID
        manager.state.lastBasalPulseSessionStart = intent.sessionStartedAt
        sync(manager, response(manager, prior), logs: [])
        XCTAssertNil(manager.state.pendingTempBasal)
        XCTAssertNil(manager.state.shortTempBasal)
        XCTAssertFalse(manager.state.basalDeliveryUncertain)
        XCTAssertEqual(manager.lastBasalPulseAt, intent.previousPulseAt)
    }

    func testRebasedAutomaticSetCheckpointUsesPostCancelBaseline() throws {
        let (manager, prior) = fixture(expired: false)
        manager.state.pendingTempBasal = nil
        manager.state.basalDeliveryUncertain = false
        let created = Date().addingTimeInterval(-5)
        let baselineAt = Date().addingTimeInterval(-1)
        manager.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: prior, sessionID: manager.state.patchId,
            sessionStartedAt: manager.state.patchActivatedAt!, observedAt: baselineAt)
        let template = try XCTUnwrap(MedtrumShortTempBasal(sessionID: manager.state.patchId,
            sessionStartedAt: manager.state.patchActivatedAt!, commandID: UUID(), rate: 6,
            minutes: 1, requestedAt: created, automatic: true))
        let prepared = try XCTUnwrap(template.preparedForWrite(at: Date(), uptime: 100))
        let request = UnfinalizedDose(decisionId: prepared.commandID, tempRate: prepared.rate, duration: 1800,
            insulinType: nil, automatic: true, startDate: prepared.requestedAt)
        XCTAssertNotNil(manager.captureBasalRecoveryCheckpoint(for: request))
    }

    private func fixture(expired: Bool = true) -> (MedtrumPumpManager, BasalData) {
        let now = Date()
        let start = now.addingTimeInterval(expired ? -3600 : -60)
        let state = MedtrumPumpState(nil)
        state.pumpSN = Data([1, 2, 3, 4])
        state.patchId = UInt64(256).toData(length: 4)
        state.patchActivatedAt = now.addingTimeInterval(-7200)
        state.patchSessionEnded = false
        state.pumpState = .active
        state.basalState = .active
        state.basalDose = UnfinalizedDose(basalRate: 0.8, insulinType: nil, startDate: start)
        state.pendingTempBasal = UnfinalizedDose(decisionId: UUID(), tempRate: 1.1, duration: 1800,
            insulinType: nil, automatic: true, startDate: start.addingTimeInterval(0.4))
        state.basalDeliveryUncertain = true
        state.legacyBasalRecoveryAllowed = true
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        installStorage(manager)
        return (manager, BasalData(type: .STANDARD, sequence: 907, patchId: 256,
            startTime: start.addingTimeInterval(4), rate: 0.8, delivery: 0.5))
    }

    private func installStorage(_ manager: MedtrumPumpManager) {
        manager.persistPendingDelivery = {}
        manager.persistBasalRecovery = { transaction in try transaction { _ in } }
    }

    private func response(_ manager: MedtrumPumpManager, _ basal: BasalData,
                          state: PatchState = .active) -> SynchronizePacketResponse {
        var result = SynchronizePacketResponse(state: state, activeAlarms: [])
        result.basal = basal
        result.storage = StorageData(sequence: basal.sequence, patchId: basal.patchId)
        result.startTime = manager.state.patchActivatedAt
        return result
    }

    private func evidence(_ manager: MedtrumPumpManager) -> [MedtrumBasalRecoveryLogEntry] {
        let request = manager.state.pendingTempBasal!
        let prior = BasalData(type: .ABSOLUTE_TEMP, sequence: 906, patchId: 256,
            startTime: request.startDate.addingTimeInterval(-300), rate: 1.9, delivery: 0.1)
        let packet = response(manager, prior)
        return [entry(manager, packet, at: request.startDate.addingTimeInterval(-140))]
    }

    private func entry(_ manager: MedtrumPumpManager, _ packet: SynchronizePacketResponse,
                       at date: Date) -> MedtrumBasalRecoveryLogEntry {
        let json = String(data: try! JSONEncoder().encode(packet), encoding: .utf8)!
        return MedtrumBasalRecoveryLogEntry(timestamp: date, deviceIdentifier: manager.logDeviceIdentifier,
            message: "[INFO] PeripheralManager.swift - parseStateUpdate(_:duringReconnect:fullSync:)#256: State update: " + json)
    }

    private func sync(_ manager: MedtrumPumpManager, _ packet: SynchronizePacketResponse,
                      logs: [MedtrumBasalRecoveryLogEntry]? = nil,
                      query: MedtrumBasalSyncContext? = nil, full: Bool = true) {
        StateSyncer.sync(syncResponse: packet, state: manager.state, pumpManager: manager,
            duringReconnect: true, fullSync: full, recoveryQuery: query ?? manager.captureBasalSyncContext(),
            legacyEvidence: logs ?? evidence(manager))
    }

    private func observation(_ manager: MedtrumPumpManager, at date: Date) {
        manager.verifiedPumpObservation = MedtrumVerifiedPumpObservation(sessionID: manager.state.patchId,
            sessionStart: manager.state.patchActivatedAt!, date: date)
    }

    func testFreshCacheReturnsRealVerifiedObservationForDeferredLoop() {
        let (manager, _) = fixture()
        manager.state.basalDeliveryUncertain = false
        manager.state.pendingTempBasal = nil
        let expected = Date().addingTimeInterval(-21)
        manager.state.lastSync = Date()
        observation(manager, at: expected)
        var observed: Date?
        manager.ensureCurrentPumpData { observed = $0 }
        XCTAssertEqual(observed, expected)
    }

    func testGenericRecentSyncCannotMasqueradeAsVerifiedData() {
        let (manager, _) = fixture()
        manager.state.basalDeliveryUncertain = false
        manager.state.pendingTempBasal = nil
        manager.state.lastSync = Date()
        XCTAssertNil(manager.cachedPumpDataDate(at: Date()))
    }

    func testUnknownStaleFutureAndInactiveCacheCannotPassFreshness() {
        let (manager, _) = fixture()
        manager.state.basalDeliveryUncertain = false
        let now = Date()
        for age in [-5.0, 271, 600] {
            observation(manager, at: now.addingTimeInterval(-age))
            XCTAssertNil(manager.cachedPumpDataDate(at: now))
        }
        observation(manager, at: now)
        manager.state.basalDeliveryUncertain = true
        XCTAssertNil(manager.cachedPumpDataDate(at: now))
        manager.state.basalDeliveryUncertain = false
        manager.state.patchSessionEnded = true
        XCTAssertNil(manager.cachedPumpDataDate(at: now))
    }

    func testBuild35ExpiredPendingUsesIndependentPredecessorAndKeepsHistory() {
        let (manager, basal) = fixture()
        let start = manager.state.basalDose.startDate
        var oldRaw = manager.rawState
        oldRaw.removeValue(forKey: "basalRecoveryVersion")
        oldRaw.removeValue(forKey: "legacyBasalRecoveryAllowed")
        let restored = MedtrumPumpManager(state: MedtrumPumpState(rawValue: oldRaw), bluetooth: nil)
        installStorage(restored)
        sync(restored, response(restored, basal))
        XCTAssertFalse(restored.status.deliveryIsUncertain)
        XCTAssertNil(restored.state.pendingTempBasal)
        XCTAssertEqual(restored.state.basalDose.startDate, start)
        XCTAssertEqual(restored.state.basalDose.value, 0.8)
        XCTAssertFalse(MedtrumPumpState(rawValue: restored.rawState).basalDeliveryUncertain)
    }

    func testTimestampApproximationAloneCannotUnlockBuild35() {
        let (manager, basal) = fixture()
        sync(manager, response(manager, basal), logs: [])
        XCTAssertTrue(manager.status.deliveryIsUncertain)
        XCTAssertNotNil(manager.state.pendingTempBasal)
    }

    func testPostRequestOrForeignDeviceEvidenceCannotUnlock() {
        for condition in 0..<3 {
            let (manager, basal) = fixture()
            let original = evidence(manager)[0]
            let log = MedtrumBasalRecoveryLogEntry(
                timestamp: condition == 0 ? manager.state.pendingTempBasal!.startDate : original.timestamp,
                deviceIdentifier: condition == 1 ? "different-pump" : original.deviceIdentifier,
                message: condition == 2 ? "[INFO] unknown: " + original.message : original.message)
            sync(manager, response(manager, basal), logs: [log])
            XCTAssertTrue(manager.status.deliveryIsUncertain)
        }
    }

    func testNewerConflictingPartialPacketInvalidatesLegacyPredecessor() {
        let (manager, basal) = fixture()
        var logs = evidence(manager)
        var newer = response(manager, basal)
        newer.startTime = nil
        newer.storage = nil
        logs.append(entry(manager, newer, at: manager.state.pendingTempBasal!.startDate.addingTimeInterval(-10)))
        sync(manager, response(manager, basal), logs: logs)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }

    func testMatchingPartialPacketPreservesIndependentFullPredecessor() {
        let (manager, basal) = fixture()
        var logs = evidence(manager)
        var prior = try! JSONDecoder().decode(SynchronizePacketResponse.self,
            from: Data(logs[0].message.components(separatedBy: "State update: ")[1].utf8))
        prior.startTime = nil
        prior.storage = nil
        logs.append(entry(manager, prior, at: manager.state.pendingTempBasal!.startDate.addingTimeInterval(-10)))
        sync(manager, response(manager, basal), logs: logs)
        XCTAssertFalse(manager.state.basalDeliveryUncertain)
    }

    func testLegacyCannotUnlockBeforeExpiryOrAfterAdditionalNativeSegments() {
        for condition in 0..<2 {
            let (manager, basal) = fixture(expired: condition != 0)
            let actual = condition == 1 ? BasalData(type: .STANDARD, sequence: 908, patchId: 256,
                startTime: basal.startTime, rate: 0.8, delivery: 0.5) : basal
            sync(manager, response(manager, actual))
            XCTAssertTrue(manager.status.deliveryIsUncertain)
        }
    }

    func testCheckpointPersistsAndResolvesBeforeExpiryWithConservativeLiveSnapshot() throws {
        let (manager, basal) = fixture(expired: false)
        let request = try XCTUnwrap(manager.state.pendingTempBasal)
        manager.state.pendingTempBasal = nil
        manager.state.basalDeliveryUncertain = false
        manager.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: basal, sessionID: manager.state.patchId,
            sessionStartedAt: manager.state.patchActivatedAt!, observedAt: request.startDate.addingTimeInterval(-0.1))
        try manager.checkpointBasal(requested: request)
        let restored = MedtrumPumpManager(state: MedtrumPumpState(rawValue: manager.rawState), bluetooth: nil)
        XCTAssertNotNil(restored.state.basalRecoveryCheckpoint)
        var committed: MedtrumPumpState?
        restored.persistBasalRecovery = { transaction in
            try transaction { candidate in
                XCTAssertTrue(restored.status.deliveryIsUncertain)
                XCTAssertTrue(MedtrumPumpState(rawValue: restored.rawState).basalDeliveryUncertain)
                committed = MedtrumPumpState(rawValue: candidate)
            }
        }
        sync(restored, response(restored, basal))
        XCTAssertFalse(restored.status.deliveryIsUncertain)
        XCTAssertNil(restored.state.pendingTempBasal)
        XCTAssertEqual(committed?.basalDeliveryUncertain, false)
    }

    func testAutomaticCheckpointRejectsMissingOrInvalidatedNativeBaseline() {
        let (manager, basal) = fixture(expired: false)
        let request = manager.state.pendingTempBasal!
        manager.state.pendingTempBasal = nil
        manager.state.basalDeliveryUncertain = false
        manager.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: basal, sessionID: manager.state.patchId,
            sessionStartedAt: manager.state.patchActivatedAt!, observedAt: request.startDate.addingTimeInterval(-1))
        manager.invalidateBasalObservation()
        XCTAssertThrowsError(try manager.checkpointBasal(requested: request))
        XCTAssertNil(manager.state.pendingTempBasal)
        XCTAssertFalse(manager.state.awaitingBasalReply)
    }

    func testNativeBaselineAdmissionSurvivesResumeAndScheduledRateChanges() {
        for resumed in [false, true] {
            let (manager, basal) = fixture(expired: false)
            let request = manager.state.pendingTempBasal!
            manager.state.pendingTempBasal = nil
            manager.state.basalDeliveryUncertain = false
            manager.state.basalDose = resumed ? UnfinalizedDose(resumeStartTime: request.startDate, insulinType: nil) :
                UnfinalizedDose(basalRate: 0.7, insulinType: nil, startDate: request.startDate)
            manager.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: basal, sessionID: manager.state.patchId,
                sessionStartedAt: manager.state.patchActivatedAt!, observedAt: request.startDate.addingTimeInterval(-1))
            XCTAssertNoThrow(try manager.checkpointBasal(requested: request))
        }
    }

    func testQueryStartedBeforeCommandCannotResolveFailedWrite() {
        let (manager, basal) = fixture()
        let staleQuery = manager.captureBasalSyncContext()
        manager.deliveryGeneration = UUID()
        sync(manager, response(manager, basal), query: staleQuery)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
        XCTAssertNil(manager.verifiedPumpObservation)
    }

    func testQueryCapturedWhileSubmittingCannotRecover() {
        let (manager, basal) = fixture()
        manager.submittingDelivery = true
        let query = manager.captureBasalSyncContext()
        manager.submittingDelivery = false
        sync(manager, response(manager, basal), query: query)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }

    func testConflictingActivationCannotBecomeValidOnSecondQuery() {
        let (manager, basal) = fixture()
        let activation = manager.state.patchActivatedAt
        var packet = response(manager, basal)
        packet.startTime = activation?.addingTimeInterval(3600)
        sync(manager, packet)
        sync(manager, packet)
        XCTAssertEqual(manager.state.patchActivatedAt, activation)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
        XCTAssertNil(manager.verifiedPumpObservation)
    }

    func testConfirmedTempWithWrongActivationCannotUnlock() {
        let (manager, _) = fixture(expired: false)
        let request = manager.state.pendingTempBasal!
        let temp = BasalData(type: .ABSOLUTE_TEMP, sequence: 908, patchId: 256,
            startTime: request.startDate, rate: request.value, delivery: 0.1)
        var packet = response(manager, temp)
        packet.startTime = manager.state.patchActivatedAt?.addingTimeInterval(60)
        sync(manager, packet)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }

    func testInvalidIncompleteWrongPatchAndUnverifiedStatusNeverUnlocks() {
        for condition in 0..<7 {
            let (manager, basal) = fixture()
            var packet = response(manager, basal)
            if condition == 0 { packet.invalidPayload = true }
            if condition == 1 { packet.truncated = true }
            if condition == 2 { manager.state.awaitingBasalReply = true }
            if condition == 3 { packet.startTime = nil }
            if condition == 4 { packet.storage = nil }
            if condition == 5 { packet.storage = StorageData(sequence: 907, patchId: 257) }
            sync(manager, packet, full: condition != 6)
            XCTAssertTrue(manager.status.deliveryIsUncertain, "condition \(condition)")
            XCTAssertNotNil(manager.state.pendingTempBasal)
        }
    }

    func testInvalidRefreshInvalidatesPreviousFreshObservation() {
        for condition in 0..<4 {
            let (manager, basal) = fixture()
            manager.state.basalDeliveryUncertain = false
            observation(manager, at: Date().addingTimeInterval(-20))
            var packet = response(manager, basal)
            if condition == 0 { packet.startTime = nil }
            if condition == 1 { packet.storage = nil }
            if condition == 2 { packet.basal = BasalData(type: .NONE, sequence: 907, patchId: 256,
                startTime: basal.startTime, rate: 0.8, delivery: 0) }
            if condition == 3 { packet.invalidPayload = true }
            sync(manager, packet)
            XCTAssertNil(manager.cachedPumpDataDate(at: Date()))
        }
    }

    func testAlternateDeliveringStateIsValidNativeObservation() {
        let (manager, basal) = fixture()
        manager.state.pumpState = .active_alt
        let packet = response(manager, basal, state: .active_alt)
        sync(manager, packet)
        XCTAssertFalse(manager.state.basalDeliveryUncertain)
        XCTAssertNotNil(manager.verifiedPumpDataDate(at: Date()))
    }

    func testFirstNativeActivationCanReplaceOnlyProvisionalEstimateWithoutPendingDelivery() {
        let (manager, basal) = fixture()
        manager.state.pendingTempBasal = nil
        manager.state.basalDeliveryUncertain = false
        manager.state.patchActivationIsProvisional = true
        var packet = response(manager, basal)
        packet.startTime = manager.state.patchActivatedAt!.addingTimeInterval(-0.4)
        sync(manager, packet, logs: [])
        XCTAssertEqual(manager.state.patchActivatedAt, packet.startTime)
        XCTAssertFalse(MedtrumPumpState(rawValue: manager.rawState).patchActivationIsProvisional)
        XCTAssertNil(manager.verifiedPumpObservation)
        sync(manager, packet, logs: [])
        XCTAssertNotNil(manager.verifiedPumpDataDate(at: Date()))
    }

    func testProvisionalActivationCannotNormalizeAnUncertainRequest() {
        let (manager, basal) = fixture()
        manager.state.patchActivationIsProvisional = true
        let activation = manager.state.patchActivatedAt
        var packet = response(manager, basal)
        packet.startTime = activation!.addingTimeInterval(-0.4)
        sync(manager, packet)
        XCTAssertEqual(manager.state.patchActivatedAt, activation)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }

    func testFreshNativeResponseAfterResumeDoesNotRequirePriorDeliveringState() {
        let (manager, basal) = fixture()
        manager.state.pendingTempBasal = nil
        manager.state.basalDeliveryUncertain = false
        manager.state.pumpState = .suspended
        sync(manager, response(manager, basal), logs: [])
        XCTAssertEqual(manager.state.pumpState, .active)
        XCTAssertNotNil(manager.verifiedPumpDataDate(at: Date()))
    }

    func testAuthoritativeHaltUpdatesStateWithoutResolvingPendingDelivery() {
        let (manager, basal) = fixture()
        let stopped = BasalData(type: .SUSPEND_MANUAL, sequence: 908, patchId: 256,
            startTime: basal.startTime, rate: 0, delivery: 0)
        let packet = response(manager, stopped, state: .suspended)
        sync(manager, packet)
        XCTAssertEqual(manager.state.pumpState, .suspended)
        XCTAssertTrue(manager.state.basalDeliveryUncertain)
        XCTAssertNotNil(manager.state.pendingTempBasal)
        XCTAssertNil(manager.verifiedPumpDataDate(at: Date()))
    }

    func testRecoveryPersistenceFailureLeavesLiveAndRestartStateBlocked() {
        let (manager, basal) = fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func store(_ raw: PumpManager.RawStateValue) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
        }
        try! store(manager.rawState)
        manager.persistBasalRecovery = { transaction in
            try transaction { _ in
                XCTAssertTrue(MedtrumPumpState(rawValue: manager.rawState).basalDeliveryUncertain)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        sync(manager, response(manager, basal))
        XCTAssertTrue(manager.status.deliveryIsUncertain)
        XCTAssertNotNil(manager.state.pendingTempBasal)
        // A subsequent ordinary delegate save must still be conservative.
        try! store(manager.rawState)
        let data = try! Data(contentsOf: url)
        let disk = try! PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! PumpManager.RawStateValue
        XCTAssertTrue(MedtrumPumpState(rawValue: disk).basalDeliveryUncertain)
        XCTAssertFalse(manager.basalRecoveryInProgress)
    }

    func testCorruptCheckpointCannotDowngradeToLegacyRecovery() {
        let (manager, basal) = fixture()
        var raw = manager.rawState
        raw["basalRecoveryCheckpoint"] = Data("invalid".utf8)
        let restored = MedtrumPumpManager(state: MedtrumPumpState(rawValue: raw), bluetooth: nil)
        installStorage(restored)
        sync(restored, response(restored, basal))
        XCTAssertTrue(restored.status.deliveryIsUncertain)
        XCTAssertFalse(MedtrumPumpState(rawValue: restored.rawState).legacyBasalRecoveryAllowed)
    }

    func testIndependentBolusUncertaintyIsNeverClearedByBasalRecovery() {
        let (manager, basal) = fixture()
        manager.state.bolusDeliveryUncertain = true
        sync(manager, response(manager, basal))
        XCTAssertNil(manager.state.pendingTempBasal)
        XCTAssertFalse(manager.state.basalDeliveryUncertain)
        XCTAssertTrue(manager.state.bolusDeliveryUncertain)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }

    func testEvidenceProviderCompletesOnlyOnceWhenHostCallsTwice() {
        let (manager, _) = fixture()
        var count = 0
        manager.legacyBasalEvidenceProvider = { _, complete in complete([]); complete([]) }
        manager.withLegacyBasalEvidence(for: manager.captureBasalSyncContext()) { _ in count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testConfirmedNativeTempCommitsHistoryOnlyAfterDurableSave() throws {
        for fails in [false, true] {
            let (manager, _) = fixture(expired: false)
            let request = try XCTUnwrap(manager.state.pendingTempBasal)
            let originalStart = manager.state.basalDose.startDate
            let nativeStart = request.startDate.addingTimeInterval(2)
            let temp = BasalData(type: .ABSOLUTE_TEMP, sequence: 908, patchId: 256,
                startTime: nativeStart, rate: request.value, delivery: 0.1)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            func store(_ raw: PumpManager.RawStateValue) throws {
                let bytes = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
                try bytes.write(to: url, options: .atomic)
            }
            try store(manager.rawState)
            manager.persistBasalRecovery = { transaction in
                try transaction { candidate in
                    XCTAssertTrue(manager.state.basalDeliveryUncertain)
                    XCTAssertEqual(manager.state.basalDose.startDate, originalStart)
                    if fails { throw CocoaError(.fileWriteUnknown) }
                    try store(candidate)
                }
            }
            sync(manager, response(manager, temp))
            let bytes = try Data(contentsOf: url)
            let raw = try XCTUnwrap(try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
                as? PumpManager.RawStateValue)
            let restarted = MedtrumPumpState(rawValue: raw)
            XCTAssertEqual(manager.state.basalDeliveryUncertain, fails)
            XCTAssertEqual(restarted.basalDeliveryUncertain, fails)
            XCTAssertEqual(manager.state.pendingTempBasal == nil, !fails)
            XCTAssertEqual(restarted.pendingTempBasal == nil, !fails)
            XCTAssertEqual(manager.state.basalDose.startDate, fails ? originalStart : nativeStart)
            XCTAssertEqual(restarted.basalDose.startDate, fails ? originalStart : nativeStart)
            if !fails {
                XCTAssertEqual(restarted.basalDose.type, .tempBasal)
                XCTAssertEqual(restarted.basalDose.value, request.value)
            }
        }
    }

    func testStateChangeWhileHostQueueWaitsCannotCommitRecovery() {
        let (manager, basal) = fixture()
        var saves = 0
        manager.persistBasalRecovery = { transaction in
            // A command/session invalidation while waiting to enter the host serial queue.
            manager.invalidateBasalObservation()
            try transaction { _ in saves += 1 }
        }
        sync(manager, response(manager, basal))
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(manager.state.basalDeliveryUncertain)
        XCTAssertNotNil(manager.state.pendingTempBasal)
        XCTAssertTrue(MedtrumPumpState(rawValue: manager.rawState).basalDeliveryUncertain)
        XCTAssertFalse(manager.basalRecoveryInProgress)
    }

    func testUntrustedStatusInvalidatesObservationWithoutDeletingSession() {
        for condition in 0..<4 {
            let (manager, basal) = fixture()
            manager.state.basalDeliveryUncertain = false
            manager.state.pendingTempBasal = nil
            observation(manager, at: Date().addingTimeInterval(-20))
            let activation = manager.state.patchActivatedAt
            var packet = response(manager, basal, state: condition == 0 ? .none : .active)
            if condition == 1 {
                packet.basal = BasalData(type: .NONE, sequence: 907, patchId: 256,
                    startTime: basal.startTime, rate: 0.8, delivery: 0)
            }
            if condition == 2 { packet.truncated = true }
            if condition == 3 { packet.storage = StorageData(sequence: 907, patchId: 257) }
            sync(manager, packet, logs: [], full: condition == 0)
            XCTAssertNil(manager.cachedPumpDataDate(at: Date()), "condition \(condition)")
            XCTAssertFalse(manager.state.patchSessionEnded)
            XCTAssertEqual(manager.state.patchActivatedAt, activation)
            XCTAssertEqual(manager.state.patchId, UInt64(256).toData(length: 4))
        }
    }
}

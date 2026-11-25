@testable import MedtrumKit
import LoopKit
import XCTest

final class DeliveryRecoveryTests: XCTestCase {
    private func fixture(expired: Bool = true) -> (MedtrumPumpManager, BasalData) {
        let now = Date()
        let start = now.addingTimeInterval(expired ? -3600 : -60)
        let state = MedtrumPumpState(nil)
        state.patchId = UInt64(256).toData(length: 4)
        state.patchActivatedAt = now.addingTimeInterval(-7200)
        state.patchSessionEnded = false
        state.pumpState = .active
        state.basalState = .active
        state.pumpTime = now.addingTimeInterval(4)
        state.pumpTimeSyncedAt = now
        state.basalDose = UnfinalizedDose(basalRate: 0.8, insulinType: nil, startDate: start)
        state.pendingTempBasal = UnfinalizedDose(decisionId: UUID(), tempRate: 1.1, duration: 1800,
            insulinType: nil, automatic: true, startDate: start.addingTimeInterval(0.4))
        state.basalDeliveryUncertain = true
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.persistPendingDelivery = {}
        return (manager, BasalData(type: .STANDARD, sequence: 907, patchId: 256,
            startTime: start.addingTimeInterval(4), rate: 0.8, delivery: 0.5))
    }

    private func response(_ manager: MedtrumPumpManager, _ basal: BasalData) -> SynchronizePacketResponse {
        var result = SynchronizePacketResponse(state: .active, activeAlarms: [])
        result.basal = basal
        result.storage = StorageData(sequence: basal.sequence, patchId: basal.patchId)
        result.startTime = manager.state.patchActivatedAt
        return result
    }

    func testFreshCacheReturnsRealObservationForDeferredLoop() {
        let (manager, _) = fixture()
        manager.state.basalDeliveryUncertain = false
        manager.state.pendingTempBasal = nil
        manager.state.lastSync = Date().addingTimeInterval(-21)
        let expected = manager.state.lastSync
        var observed: Date?
        manager.ensureCurrentPumpData { observed = $0 }
        XCTAssertEqual(observed, expected, "Skipping a refresh must return the real fresh observation, not nil or now")
    }

    func testUnknownStaleFutureAndInactiveCacheCannotPassFreshness() {
        let (manager, _) = fixture()
        manager.state.basalDeliveryUncertain = false
        manager.state.pendingTempBasal = nil
        let now = Date()
        for age in [-5.0, 271, 600] {
            manager.state.lastSync = now.addingTimeInterval(-age)
            XCTAssertNil(manager.cachedPumpDataDate(at: now))
        }
        manager.state.lastSync = now
        manager.state.basalDeliveryUncertain = true
        XCTAssertNil(manager.cachedPumpDataDate(at: now))
        manager.state.basalDeliveryUncertain = false
        manager.state.patchSessionEnded = true
        XCTAssertNil(manager.cachedPumpDataDate(at: now))
    }

    func testBuild35ExpiredPendingRestoresWithoutDeletingBasalHistory() {
        let (manager, basal) = fixture()
        let originalStart = manager.state.basalDose.startDate
        let originalRate = manager.state.basalDose.value
        let restored = MedtrumPumpManager(state: MedtrumPumpState(rawValue: manager.rawState), bluetooth: nil)
        restored.persistPendingDelivery = {}
        StateSyncer.sync(syncResponse: response(restored, basal), state: restored.state,
            pumpManager: restored, duringReconnect: true, fullSync: true)
        XCTAssertFalse(restored.status.deliveryIsUncertain)
        XCTAssertNil(restored.state.pendingTempBasal)
        XCTAssertEqual(restored.state.basalDose.startDate, originalStart)
        XCTAssertEqual(restored.state.basalDose.value, originalRate)
        XCTAssertFalse(MedtrumPumpState(rawValue: restored.rawState).basalDeliveryUncertain)
    }

    func testCheckpointPersistsNativeBaselineAndResolvesLostReplyBeforeExpiry() throws {
        let (manager, basal) = fixture(expired: false)
        let request = try XCTUnwrap(manager.state.pendingTempBasal)
        manager.state.pendingTempBasal = nil
        manager.state.basalDeliveryUncertain = false
        manager.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: basal, sessionID: manager.state.patchId,
            sessionStartedAt: manager.state.patchActivatedAt!, observedAt: request.startDate.addingTimeInterval(-0.1))
        try manager.checkpointBasal(requested: request)
        XCTAssertNotNil(manager.state.basalRecoveryCheckpoint)
        let restoredState = MedtrumPumpState(rawValue: manager.rawState)
        XCTAssertNotNil(restoredState.basalRecoveryCheckpoint)
        let restored = MedtrumPumpManager(state: restoredState, bluetooth: nil)
        restored.persistPendingDelivery = {
            XCTAssertTrue(restored.status.deliveryIsUncertain, "No new command during durable recovery")
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = restored.rawState; read.signal() }
            XCTAssertEqual(read.wait(timeout: .now() + 1), .success, "Persistence must not hold deliveryLock")
        }
        StateSyncer.sync(syncResponse: response(restored, basal), state: restored.state,
            pumpManager: restored, duringReconnect: true, fullSync: true)
        XCTAssertNil(restored.state.pendingTempBasal)
        XCTAssertFalse(restored.status.deliveryIsUncertain)
    }

    func testInvalidCachedDifferentOrLaterStatusNeverUnlocks() {
        for condition in 0..<9 {
            let (manager, basal) = fixture()
            var result = response(manager, basal)
            if condition == 0 { result.invalidPayload = true }
            if condition == 1 { result.truncated = true }
            if condition == 2 { manager.state.awaitingBasalReply = true }
            if condition == 3 { result.basal = BasalData(type: .STANDARD, sequence: 908, patchId: 257,
                startTime: basal.startTime, rate: 0.8, delivery: 0) }
            if condition == 4 { result.basal = BasalData(type: .STANDARD, sequence: 908, patchId: 256,
                startTime: Date().addingTimeInterval(-60), rate: 0.8, delivery: 0) }
            if condition == 5 { result.basal = BasalData(type: .STANDARD, sequence: 907, patchId: 256,
                startTime: basal.startTime, rate: 1, delivery: 0) }
            if condition == 6 { manager.state.pumpTimeSyncedAt = Date().addingTimeInterval(-4000) }
            if condition == 7 { result.startTime = manager.state.patchActivatedAt?.addingTimeInterval(3600) }
            StateSyncer.sync(syncResponse: result, state: manager.state, pumpManager: manager,
                duringReconnect: true, fullSync: condition != 8)
            XCTAssertTrue(manager.state.basalDeliveryUncertain, "condition \(condition)")
            XCTAssertNotNil(manager.state.pendingTempBasal, "condition \(condition)")
        }
    }

    func testLegacyRequestBeforeExpiryCannotBeAssumedNeverExecuted() {
        let (manager, basal) = fixture(expired: false)
        StateSyncer.sync(syncResponse: response(manager, basal), state: manager.state,
            pumpManager: manager, duringReconnect: true, fullSync: true)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
        XCTAssertNotNil(manager.state.pendingTempBasal)
    }

    func testInvalidFullSyncDoesNotRefreshObservationDate() {
        let (manager, basal) = fixture()
        let oldDate = Date().addingTimeInterval(-600)
        manager.state.lastSync = oldDate
        var result = response(manager, basal)
        result.invalidPayload = true
        StateSyncer.sync(syncResponse: result, state: manager.state, pumpManager: manager,
            duringReconnect: true, fullSync: true)
        XCTAssertEqual(manager.state.lastSync, oldDate)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }

    func testRecoveryPersistenceFailureLeavesDeliveryBlocked() {
        let (manager, basal) = fixture()
        manager.persistPendingDelivery = { throw CocoaError(.fileWriteUnknown) }
        StateSyncer.sync(syncResponse: response(manager, basal), state: manager.state,
            pumpManager: manager, duringReconnect: true, fullSync: true)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
        XCTAssertNotNil(manager.state.pendingTempBasal)
    }

    func testIndependentBolusUncertaintyIsNeverClearedByBasalRecovery() {
        let (manager, basal) = fixture()
        manager.state.bolusDeliveryUncertain = true
        StateSyncer.sync(syncResponse: response(manager, basal), state: manager.state,
            pumpManager: manager, duringReconnect: true, fullSync: true)
        XCTAssertNil(manager.state.pendingTempBasal)
        XCTAssertFalse(manager.state.basalDeliveryUncertain)
        XCTAssertTrue(manager.state.bolusDeliveryUncertain)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }
}

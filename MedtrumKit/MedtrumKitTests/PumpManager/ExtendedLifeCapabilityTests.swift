@testable import MedtrumKit
import XCTest

final class ExtendedLifeCapabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(age: TimeInterval = 432_000) -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.pumpSN = Data([18, 187, 192, 52]) // synthetic MD8301 model fixture
        state.lastSync = now
        state.reservoir = 50
        state.pumpState = .active
        state.patchSessionEnded = false
        state.patchId = Data([1, 0, 0, 0])
        state.patchActivatedAt = now.addingTimeInterval(-age)
        state.expiryMode = .extended
        return state
    }

    func testOnlyExtendedSessionLosesAutomaticBolusAtFiveDays() {
        let old = state()
        XCTAssertEqual(old.model, "MD8301")
        let manager = MedtrumPumpManager(state: old, bluetooth: nil)
        XCTAssertFalse(manager.automaticBolusContext(at: now).allowsAutomaticBolus)
        XCTAssertTrue(old.isExtendedBasalOnly(at: now))
        old.expiryMode = .default
        XCTAssertFalse(manager.automaticBolusContext(at: now).allowsAutomaticBolus)
        XCTAssertTrue(old.isExtendedBasalOnly(at: now))
    }

    func testUnsupportedModelDoesNotAcquireAnExtendedRestriction() {
        let other = state()
        other.pumpSN = Data()
        XCTAssertTrue(MedtrumPumpManager(state: other, bluetooth: nil).automaticBolusContext(at: now).allowsAutomaticBolus)
    }

    func testBasalOnlyPresentationRequiresConfirmedAvailableDelivery() {
        for condition in 0 ... 3 {
            let old = state()
            if condition == 0 { old.basalState = .suspended }
            if condition == 1 { old.reservoir = 0 }
            if condition == 2 { old.lastSync = now.addingTimeInterval(-721) }
            if condition == 3 { old.basalDeliveryUncertain = true }
            XCTAssertFalse(old.canShowExtendedBasalOnlyStatus(at: now))
        }
    }

    func testUnidentifiedAgeCannotBeAttachedToTheCurrentPatch() {
        let young = state(age: 60)
        let manager = MedtrumPumpManager(state: young, bluetooth: nil)
        let response = SynchronizePacketResponse(state: .active, startTime: now.addingTimeInterval(-500_000),
                                                activeAlarms: [], patchAge: 500_000)
        StateSyncer.sync(syncResponse: response, state: young, pumpManager: manager, duringReconnect: false, fullSync: true)
        XCTAssertFalse(young.isExtendedBasalOnly(at: now))
        XCTAssertEqual(young.patchActivatedAt, now.addingTimeInterval(-60))
    }

    func testDeviceAgeSurvivesStateRestorationAndDoesNotLeakIntoANewPatch() {
        let original = state(age: 60)
        original.extendedLifePolicy.observe(age: 500_000, sessionID: original.patchId, at: now)
        let restored = MedtrumPumpState(rawValue: original.rawValue)
        XCTAssertTrue(restored.isExtendedBasalOnly(at: now))
        restored.patchId = Data([2, 0, 0, 0])
        restored.patchActivatedAt = now
        XCTAssertFalse(restored.isExtendedBasalOnly(at: now))
        XCTAssertTrue(MedtrumPumpManager(state: restored, bluetooth: nil)
            .automaticBolusContext(at: now).allowsAutomaticBolus)
    }

    func testFaultOrSuspensionCannotBePresentedAsBasalOnly() {
        for pumpState in [PatchState.expired, .occlusion, .suspended, .paused, .reservoirEmpty, .stopped] {
            let stopped = state()
            stopped.pumpState = pumpState
            XCTAssertFalse(stopped.isExtendedBasalOnly(at: now))
            XCTAssertFalse(MedtrumPumpManager(state: stopped, bluetooth: nil)
                .automaticBolusContext(at: now).allowsAutomaticBolus)
        }
    }

    func testOriginalDecisionGuardRejectsBothCommandsBeforeAnyConnectionOrCheckpoint() {
        let current = state(age: 60)
        let manager = MedtrumPumpManager(state: current, bluetooth: nil)
        var rejected = 0
        manager.enactGuardedAutomaticTempBasal(unitsPerHour: 1, duration: 1800, isValid: { false }) { error in
            if case .some(.configuration) = error { rejected += 1 }
        }
        manager.enactGuardedAutomaticBolus(units: 0.05, isValid: { false }) { error in
            if case .some(.configuration) = error { rejected += 1 }
        }
        XCTAssertEqual(rejected, 2)
        XCTAssertNil(current.pendingTempBasal)
        XCTAssertNil(current.bolusDose)
        XCTAssertFalse(current.awaitingBasalReply)
        XCTAssertFalse(current.awaitingBolusReply)
    }

    func testRestrictedAutomaticBolusIsRejectedBeforeBluetoothOrDoseBookkeeping() {
        let old = state()
        old.patchActivatedAt = Date().addingTimeInterval(-500_000)
        let manager = MedtrumPumpManager(state: old, bluetooth: nil)
        var rejected = false
        manager.enactBolus(decisionId: nil, units: 0.05, activationType: .automatic) { error in
            if case .some(.deviceState) = error { rejected = true }
        }
        XCTAssertTrue(rejected)
        XCTAssertNil(old.bolusDose)
        XCTAssertFalse(old.awaitingBolusReply)
    }

    func testSessionAndBoundaryAppearInTheAvailabilitySnapshot() {
        let old = state(age: 431_999)
        let manager = MedtrumPumpManager(state: old, bluetooth: nil)
        let before = manager.automaticBolusContext(at: now)
        XCTAssertTrue(before.allowsAutomaticBolus)
        XCTAssertFalse(manager.automaticBolusContext(at: now.addingTimeInterval(1)).allowsAutomaticBolus)
        old.patchId = Data([2, 0, 0, 0])
        old.patchActivatedAt = now
        XCTAssertNotEqual(before.sessionID, manager.automaticBolusContext(at: now).sessionID)
    }
}

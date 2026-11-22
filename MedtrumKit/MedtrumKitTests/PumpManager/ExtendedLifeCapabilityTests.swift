@testable import MedtrumKit
import XCTest

final class ExtendedLifeCapabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(age: TimeInterval = 432_000) -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.pumpState = .active
        state.patchSessionEnded = false
        state.patchId = Data([1, 0, 0, 0])
        state.patchActivatedAt = now.addingTimeInterval(-age)
        state.expiryMode = .extended
        return state
    }

    func testOnlyExtendedSessionLosesAutomaticBolusAtFiveDays() {
        let old = state()
        let manager = MedtrumPumpManager(state: old, bluetooth: nil)
        XCTAssertFalse(manager.automaticBolusContext(at: now).allowsAutomaticBolus)
        XCTAssertTrue(old.isExtendedBasalOnly(at: now))
        old.expiryMode = .default
        XCTAssertTrue(manager.automaticBolusContext(at: now).allowsAutomaticBolus)
        XCTAssertFalse(old.isExtendedBasalOnly(at: now))
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

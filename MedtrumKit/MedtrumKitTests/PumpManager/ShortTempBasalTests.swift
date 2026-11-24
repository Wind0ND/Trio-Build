@testable import MedtrumKit
import LoopKit
import XCTest

final class ShortTempBasalTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let command = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func makeState() -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.patchId = UInt64(256).toData(length: 4)
        state.patchActivatedAt = start.addingTimeInterval(-3600)
        state.patchSessionEnded = false
        state.pumpState = .active
        state.basalState = .tempBasal
        state.basalDose = UnfinalizedDose(decisionId: command, tempRate: 6, duration: 1800,
                                         insulinType: nil, automatic: false, startDate: start)
        state.shortTempBasal = .init(sessionID: state.patchId, sessionStartedAt: state.patchActivatedAt!,
                                     commandID: command, rate: 6, minutes: 5, requestedAt: start)
        return state
    }

    private func basal(_ type: BasalType = .ABSOLUTE_TEMP, at: Date? = nil, rate: Double = 6) -> BasalData {
        BasalData(type: type, sequence: 5, patchId: 256, startTime: at ?? start, rate: rate, delivery: 0)
    }

    func testShortIntentPersistsBesideRealThirtyMinuteDose() throws {
        let state = makeState()
        let restored = MedtrumPumpState(rawValue: state.rawValue)
        XCTAssertEqual(restored.shortTempBasal, state.shortTempBasal)
        XCTAssertEqual(restored.basalDose.estimatedEndDate, start.addingTimeInterval(1800))
        XCTAssertEqual(restored.shortTempBasal?.targetEnd, start.addingTimeInterval(300))
        let manager = MedtrumPumpManager(state: restored, bluetooth: nil)
        XCTAssertEqual(manager.shortTempBasalStatus?.estimatedUnits, 0.5)
    }

    func testFullSyncConfirmsPendingIntentAfterLostReply() throws {
        let state = makeState()
        state.pendingTempBasal = state.basalDose
        state.basalDeliveryUncertain = true
        StateSyncer.reconcileShortTempBasal(state: state, basal: basal(), observedAt: start.addingTimeInterval(10), fullSync: true)
        XCTAssertEqual(state.shortTempBasal?.confirmedStart, start)
    }

    func testCachedNotificationDoesNotDiscardIntentBeforeReply() {
        let state = makeState()
        state.awaitingBasalReply = true
        StateSyncer.reconcileShortTempBasal(state: state, basal: basal(.STANDARD), observedAt: start, fullSync: false)
        XCTAssertNotNil(state.shortTempBasal)
    }

    func testFreshStatusClearsIntentAfterNaturalEndOrCancellation() {
        let state = makeState()
        StateSyncer.reconcileShortTempBasal(state: state, basal: basal(.STANDARD), observedAt: start.addingTimeInterval(400), fullSync: true)
        XCTAssertNil(state.shortTempBasal)
    }

    func testLaterManualTempAndNewPatchDoNotInheritOldDeadline() {
        let state = makeState()
        StateSyncer.reconcileShortTempBasal(state: state, basal: basal(at: start.addingTimeInterval(60)), observedAt: start.addingTimeInterval(61), fullSync: true)
        XCTAssertNil(state.shortTempBasal)
        let other = makeState()
        other.patchId = UInt64(257).toData(length: 4)
        StateSyncer.reconcileShortTempBasal(state: other, basal: basal(), observedAt: start.addingTimeInterval(10), fullSync: true)
        XCTAssertNil(other.shortTempBasal)
    }

    func testUncertainCancellationDoesNotPretendTemporaryDeliveryFinished() {
        let state = makeState()
        state.shortTempBasal = state.shortTempBasal?.confirmed(startedAt: start, observedAt: start)
        state.shortTempBasal?.cancellationFailed = true
        state.basalDeliveryUncertain = true
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        XCTAssertTrue(manager.shortTempBasalStatus?.cancellationFailed == true)
        XCTAssertEqual(state.basalDose.type, .tempBasal)
        XCTAssertEqual(state.basalDose.estimatedEndDate, start.addingTimeInterval(1800))
    }
}

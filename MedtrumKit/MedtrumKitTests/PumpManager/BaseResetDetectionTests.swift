@testable import MedtrumKit
import XCTest

final class BaseResetDetectionTests: XCTestCase {
    private func makeState(pumpState: PatchState, patchId: UInt64 = 256) -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.pumpState = pumpState
        // An activated patch's session runs
        state.patchSessionEnded = pumpState.isSetup
        state.patchId = patchId.toData(length: 4)
        return state
    }

    private func makeResponse(
        state: PatchState,
        patchId: Double? = nil,
        patchAge: UInt64? = nil
    ) -> SynchronizePacketResponse {
        var response = SynchronizePacketResponse(state: state, activeAlarms: [])
        response.storage = patchId.map { StorageData(sequence: 0, patchId: $0) }
        response.patchAge = patchAge
        return response
    }

    func testActivePatchStayingActiveIsNotAReset() {
        let check = StateSyncer.baseResetCheck(
            syncResponse: makeResponse(state: .active, patchId: 256),
            state: makeState(pumpState: .active)
        )
        XCTAssertEqual(check, .noReset)
    }

    func testActivePatchGettingSuspendedOrFaultedIsNotAReset() {
        for newState in [PatchState.suspended, .hourlyMaxSuspended, .occlusion, .stopped] {
            let check = StateSyncer.baseResetCheck(
                syncResponse: makeResponse(state: newState),
                state: makeState(pumpState: .active)
            )
            XCTAssertEqual(check, .noReset)
        }
    }

    func testSetupOfANewPatchIsNotAReset() {
        for newState in [PatchState.none, .idle, .filled, .priming, .primed] {
            let check = StateSyncer.baseResetCheck(
                syncResponse: makeResponse(state: newState, patchId: 257),
                state: makeState(pumpState: .none, patchId: 0)
            )
            XCTAssertEqual(check, .noReset)
        }
    }

    // After a deactivation the old patch, stopped, is reported until the new one is set up
    func testSetupOfANewPatchAfterTheOldOneStoppedIsNotAReset() {
        let ended = makeState(pumpState: .stopped, patchId: 0)
        ended.patchSessionEnded = true
        for newState in [PatchState.none, .idle, .filled, .priming, .primed] {
            let check = StateSyncer.baseResetCheck(syncResponse: makeResponse(state: newState, patchId: 257), state: ended)
            XCTAssertEqual(check, .noReset)
        }
    }

    // The first thing the rebooted base said on 2026-09-19: state none, next patch id, age of 1s
    func testNoneWithNewPatchIdIsAReset() {
        let check = StateSyncer.baseResetCheck(
            syncResponse: makeResponse(state: .none, patchId: 257, patchAge: 1),
            state: makeState(pumpState: .active)
        )
        XCTAssertEqual(check, .reset)
    }

    func testActivatedPatchGoingBackToSetupIsAReset() {
        for oldState in [PatchState.active, .suspended, .lowBgSuspended, .occlusion] {
            for newState in [PatchState.idle, .filled, .priming, .primed] {
                let check = StateSyncer.baseResetCheck(
                    syncResponse: makeResponse(state: newState),
                    state: makeState(pumpState: oldState)
                )
                XCTAssertEqual(check, .reset)
            }
        }
    }

    // `.none` is also what an unknown state byte parses to
    func testNoneWithoutANewPatchIdIsUnconfirmed() {
        let active = makeState(pumpState: .active)

        XCTAssertEqual(StateSyncer.baseResetCheck(syncResponse: makeResponse(state: .none), state: active), .unconfirmed)
        XCTAssertEqual(
            StateSyncer.baseResetCheck(syncResponse: makeResponse(state: .none, patchId: 256), state: active),
            .unconfirmed
        )
    }

    func testDeliveryStoppedWhenTheBaseBooted() {
        let now = Date.now
        let state = makeState(pumpState: .active)
        state.lastSync = now.addingTimeInterval(-3 * 3600)

        let stoppedAt = StateSyncer.deliveryStoppedAt(
            syncResponse: makeResponse(state: .idle, patchId: 257, patchAge: 3600),
            state: state,
            receivedAt: now
        )
        XCTAssertEqual(stoppedAt, now.addingTimeInterval(-3600))
    }

    func testDeliveryDidNotStopBeforeTheLastSync() {
        let now = Date.now
        let state = makeState(pumpState: .active)
        state.lastSync = now.addingTimeInterval(-60)

        let stoppedAt = StateSyncer.deliveryStoppedAt(
            syncResponse: makeResponse(state: .idle, patchId: 257, patchAge: 3600),
            state: state,
            receivedAt: now
        )
        XCTAssertEqual(stoppedAt, state.lastSync)
    }

    func testDeliveryStoppedNowWithoutAPatchAge() {
        let now = Date.now
        let stoppedAt = StateSyncer.deliveryStoppedAt(
            syncResponse: makeResponse(state: .idle),
            state: makeState(pumpState: .active),
            receivedAt: now
        )
        XCTAssertEqual(stoppedAt, now)
    }
}

extension BaseResetDetectionTests {
    func testWriteFailureOnlyReleasesDoseWhenCommandWasRejectedOrNeverIssued() {
        for error in [MedtrumWriteError.timeout, .invalidData, .noData] {
            XCTAssertTrue(error.deliveryMayHaveStarted)
        }
        for error in [MedtrumWriteError.noManager, .noWriteCharacteristic, .alreadyRunning, .invalidResponse(code: 1)] {
            XCTAssertFalse(error.deliveryMayHaveStarted)
        }
    }

    func testAReconnectWithoutProgressPreservesLastKnownUnitsAcrossRestart() {
        let state = makeState(pumpState: .active)
        let dose = UnfinalizedDose(decisionId: nil, units: 3, duration: 120, activationType: .automatic, insulinType: nil)
        dose.deliveredUnits = 0.5
        state.bolusDose = dose
        let manager = MedtrumPumpManager(state: MedtrumPumpState(rawValue: state.rawValue), bluetooth: nil)
        manager.checkBolusDone()
        let restored = MedtrumPumpState(rawValue: manager.state.rawValue)
        XCTAssertEqual(restored.bolusDose?.deliveredUnits, 0.5)
        XCTAssertEqual(restored.bolusDose?.value, 3)
        XCTAssertTrue(restored.bolusDeliveryUncertain)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
    }
}

extension BaseResetDetectionTests {
    func testCheckpointPrecedesBasalCommandAndSurvivesRelaunch() {
        let manager = MedtrumPumpManager(state: makeState(pumpState: .active), bluetooth: nil)
        let dose = UnfinalizedDose(decisionId: UUID(), tempRate: 1.5, duration: 1800, insulinType: nil, automatic: true)
        for request in [dose, nil] as [UnfinalizedDose?] {
            var saved: MedtrumPumpState?
            manager.persistPendingDelivery = { saved = MedtrumPumpState(rawValue: manager.rawState) }
            XCTAssertNoThrow(try manager.checkpointBasal(requested: request))
            XCTAssertEqual(saved?.basalDeliveryUncertain, true)
            XCTAssertEqual(saved?.pendingTempBasal?.value, request?.value)
        }
        manager.persistPendingDelivery = { throw CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try manager.checkpointBasal(requested: dose))
        XCTAssertFalse(manager.state.awaitingBasalReply)
        XCTAssertNil(manager.state.pendingTempBasal)
    }

    func testTempBasalCannotBeReconciledFromAnOlderOrDifferentPatchRate() throws {
        let start = Date(timeIntervalSince1970: 1700000000)
        let dose = UnfinalizedDose(decisionId: UUID(), tempRate: 1, duration: 1800, insulinType: nil,
                                   automatic: true, startDate: start)
        func basal(_ at: Date, rate: Double) -> BasalData {
            BasalData(type: .ABSOLUTE_TEMP, sequence: 5, patchId: 256, startTime: at, rate: rate, delivery: 0)
        }
        let now = start.addingTimeInterval(60)
        XCTAssertNil(StateSyncer.confirmedTempBasal(dose, basal: basal(start.addingTimeInterval(-1), rate: 1), observedAt: now))
        XCTAssertNil(StateSyncer.confirmedTempBasal(dose, basal: basal(start, rate: 2), observedAt: now))
        let matched = try XCTUnwrap(StateSyncer.confirmedTempBasal(dose, basal: basal(start, rate: 1), observedAt: now))
        XCTAssertEqual(matched.decisionId, dose.decisionId)
        XCTAssertEqual(matched.estimatedEndDate, start.addingTimeInterval(1800))
    }

    func testPatchReminderHonorsElapsedWearAndExpiry() {
        let activation = Date()
        let reminder = MedtrumAlert.patchReminder(activatedAt: activation, afterActivation: 72 * 3600,
                                                  now: activation.addingTimeInterval(12 * 3600))
        guard case let .patchExpiredNotification(after, remaining) = reminder else { XCTFail(); return }
        XCTAssertEqual(after, 60 * 3600)
        XCTAssertEqual(remaining, 8 * 3600)
        XCTAssertEqual(reminder.alert.trigger, .delayed(interval: 60 * 3600))
        XCTAssertEqual(MedtrumAlert.baseResetNotification.alert.interruptionLevel, .critical)
        XCTAssertNotNil(MedtrumAlert.baseResetNotification.alert.sound)
    }
}

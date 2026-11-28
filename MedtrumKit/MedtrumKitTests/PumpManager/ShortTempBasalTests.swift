@testable import MedtrumKit
import LoopKit
import MedtrumLifecycleKit
import XCTest

final class ShortTempBasalTests: XCTestCase {
    func testExtendedLifetimeEndsAt144HoursWithoutExtraGrace() throws {
        let state = makeState()
        let activated = try XCTUnwrap(state.patchActivatedAt)
        state.expiryMode = .extended
        XCTAssertEqual(state.patchGracePeriodFrom, activated.addingTimeInterval(518_400))
        XCTAssertEqual(state.patchExpiresAt, activated.addingTimeInterval(518_400))
        let restored = MedtrumPumpState(rawValue: state.rawValue)
        XCTAssertEqual(restored.patchExpiresAt, activated.addingTimeInterval(518_400))
        state.expiryMode = .default
        XCTAssertEqual(state.patchGracePeriodFrom, activated.addingTimeInterval(259_200))
        XCTAssertEqual(state.patchExpiresAt, activated.addingTimeInterval(288_000))
    }

    func testExtendedPulseWindowIncludes120And128ButEndsAt144() throws {
        let state = makeState()
        state.pumpSN = Data([18, 187, 192, 52])
        state.expiryMode = .extended
        state.patchActivationIsProvisional = false
        let activated = try XCTUnwrap(state.patchActivatedAt)
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        for (seconds, expected) in [(431_999.0, false), (432_000, true),
                                    (460_799, true), (460_800, true),
                                    (518_399, true), (518_400, false), (518_401, false)] {
            XCTAssertEqual(manager.isExtendedPulseWindow(at: activated.addingTimeInterval(seconds)), expected,
                "patch age seconds: \(seconds)")
        }
        state.patchId = Data([2, 0, 0, 0])
        state.patchActivatedAt = activated.addingTimeInterval(460_800)
        XCTAssertFalse(manager.isExtendedPulseWindow(at: activated.addingTimeInterval(460_801)))
    }

    func testExtendedPulseWindowDoesNotGrantCapabilityToUnavailableSessions() throws {
        for condition in 0 ... 7 {
            let state = makeState()
            state.pumpSN = Data([18, 187, 192, 52])
            state.expiryMode = .extended
            state.patchActivationIsProvisional = false
            let now = try XCTUnwrap(state.patchActivatedAt).addingTimeInterval(460_800)
            switch condition {
            case 0: state.expiryMode = .default
            case 1: state.pumpSN = Data()
            case 2: state.patchActivationIsProvisional = true
            case 3: state.patchSessionEnded = true
            case 4: state.pumpState = .suspended
            case 5: state.pumpState = .batteryOut
            case 6: state.patchActivatedAt = nil
            default: state.patchId = Data()
            }
            XCTAssertFalse(MedtrumPumpManager(state: state, bluetooth: nil).isExtendedPulseWindow(at: now))
        }
    }

    func testOriginalCompanionKeepsParentThroughPreWritePreparation() throws {
        for rate in [0.0, 0.4, 1.0, 1.2] {
            let state = makeState()
            var parent = try XCTUnwrap(MedtrumShortTempBasal(sessionID: state.patchId,
                sessionStartedAt: state.patchActivatedAt!, commandID: command, rate: 6,
                minutes: 1, requestedAt: start, automatic: true))
            parent.pulseBudget = 0.1
            parent.pulseCompanionRate = rate
            parent.pulseCompanionEnd = start.addingTimeInterval(1800)
            state.shortTempBasal = nil
            state.basalPulseContinuation = parent
            let manager = MedtrumPumpManager(state: state, bluetooth: nil)
            let protective = MedtrumBasalPulsePlan.permitsProtectiveInterruption(
                rate: rate, duration: 1740, scheduledRate: 1, pulseRate: 6)
            manager.preparePulseContinuationForWrite(protectiveInterrupt: protective, continuationOf: command)
            XCTAssertEqual(state.basalPulseContinuation, parent, "Companion rate \(rate) must retain its write-validation owner")
            XCTAssertTrue(manager.hasActiveBasalPulse)
        }
    }

    func testStaleCompanionCannotEraseCurrentParent() throws {
        let state = makeState()
        var parent = try XCTUnwrap(state.shortTempBasal)
        parent.pulseBudget = 0.1
        state.basalPulseContinuation = parent
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.preparePulseContinuationForWrite(protectiveInterrupt: true, continuationOf: UUID())
        XCTAssertEqual(state.basalPulseContinuation, parent)
    }

    func testExternalProtectiveRequestDiscardsContinuationButOrdinaryRequestDoesNot() throws {
        let state = makeState()
        let parent = try XCTUnwrap(state.shortTempBasal)
        state.basalPulseContinuation = parent
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.preparePulseContinuationForWrite(protectiveInterrupt: false, continuationOf: nil)
        XCTAssertEqual(state.basalPulseContinuation, parent)
        manager.preparePulseContinuationForWrite(protectiveInterrupt: true, continuationOf: nil)
        XCTAssertNil(state.basalPulseContinuation)
    }

    func testPulseCapabilityRequiresKnownModelAndNonProvisionalActiveSession() {
        let state = makeState()
        state.pumpSN = Data([18, 187, 192, 52])
        state.shortTempBasal = nil
        state.patchActivationIsProvisional = false
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        XCTAssertTrue(manager.supportsAutomaticBasalPulse)
        state.patchActivationIsProvisional = true
        XCTAssertFalse(manager.supportsAutomaticBasalPulse)
        state.patchActivationIsProvisional = false
        state.patchSessionEnded = true
        XCTAssertFalse(manager.supportsAutomaticBasalPulse)
    }

    func testAutomaticPulseRestoresAsActualAutomaticBasalWithoutManualFlag() throws {
        let state = makeState()
        var intent = try XCTUnwrap(MedtrumShortTempBasal(sessionID: state.patchId, sessionStartedAt: state.patchActivatedAt!,
            commandID: command, rate: 6, minutes: 1, requestedAt: start, automatic: true))
        intent.pulseBudget = 0.1
        state.shortTempBasal = intent
        XCTAssertTrue(StateSyncer.reconcileShortTempBasal(state: state, basal: basal(), observedAt: start.addingTimeInterval(2), fullSync: true))
        let manager = MedtrumPumpManager(state: MedtrumPumpState(rawValue: state.rawValue), bluetooth: nil)
        XCTAssertTrue(manager.hasActiveBasalPulse)
        XCTAssertFalse(manager.hasManualTempBasal)
        XCTAssertTrue(manager.state.basalDose.automatic)
        XCTAssertEqual(manager.lastBasalPulseAt, start)
    }

    func testPulseModeRejectsAutomaticBolusBeforeTransport() {
        let state = makeState()
        state.shortTempBasal = nil
        state.basalDose = UnfinalizedDose(basalRate: 1, insulinType: nil, startDate: start)
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.automaticBasalPulseEnabled = { true }
        let done = expectation(description: "physical automatic bolus is rejected")
        manager.enactGuardedAutomaticBolus(units: 0.1, isValid: { true }) { error in
            if let error, case .deviceState = error {} else { XCTFail("Expected bolus route refusal before communication") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testPulseCompanionRetainsAbsoluteDeadlineAndClearsParentOnRestoredConfirmation() throws {
        let state = makeState()
        var original = try XCTUnwrap(MedtrumShortTempBasal(sessionID: state.patchId, sessionStartedAt: state.patchActivatedAt!,
            commandID: command, rate: 6, minutes: 1, requestedAt: start, automatic: true))
        original.pulseBudget = 0.1
        original.pulseCompanionRate = 0
        original.pulseCompanionEnd = start.addingTimeInterval(1800)
        StateSyncer.rememberPulseCompanion(state: state, ended: original, at: start.addingTimeInterval(65))
        XCTAssertEqual(state.basalPulseContinuation?.pulseCompanionEnd, start.addingTimeInterval(1800))
        let childID = UUID()
        var child = try XCTUnwrap(MedtrumShortTempBasal(sessionID: state.patchId, sessionStartedAt: state.patchActivatedAt!,
            commandID: childID, rate: 0, minutes: 29, requestedAt: start.addingTimeInterval(65), automatic: true))
        child.absoluteEnd = original.pulseCompanionEnd
        child.pulseParentCommandID = command
        state.shortTempBasal = child
        let restored = MedtrumPumpState(rawValue: state.rawValue)
        XCTAssertTrue(StateSyncer.reconcileShortTempBasal(state: restored,
            basal: basal(at: start.addingTimeInterval(65), rate: 0), observedAt: start.addingTimeInterval(66), fullSync: true))
        XCTAssertNil(restored.basalPulseContinuation)
        XCTAssertEqual(restored.shortTempBasal?.targetEnd, start.addingTimeInterval(1800))
    }

    func testCancellationFailureAlwaysRequestsCriticalAudibleAlert() {
        let alert = MedtrumAlert.shortTempBasalCancellationFailed.alert
        XCTAssertEqual(alert.interruptionLevel, .critical)
        XCTAssertNotNil(alert.sound?.filename)
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let command = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func makeState() -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.patchId = UInt64(256).toData(length: 4)
        state.patchActivatedAt = start.addingTimeInterval(-3600)
        state.patchSessionEnded = false
        state.pumpState = .active
        state.basalState = .tempBasal
        state.pumpTime = start
        state.pumpTimeSyncedAt = start
        state.manualBasalMaximum = 10
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
        state.shortTempBasal = state.shortTempBasal?.confirmed(startedAt: start, observedAt: start)
        StateSyncer.reconcileShortTempBasal(state: state, basal: basal(.STANDARD, at: start.addingTimeInterval(300)), observedAt: start.addingTimeInterval(400), fullSync: true)
        XCTAssertNil(state.shortTempBasal)
    }

    func testLaterManualTempAndNewPatchDoNotInheritOldDeadline() {
        let state = makeState()
        state.shortTempBasal = state.shortTempBasal?.confirmed(startedAt: start, observedAt: start)
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

    func testRejectedCommandCompletionCanReadStateFromTheHostQueue() {
        let state = makeState()
        state.basalDeliveryUncertain = true
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.enactTempBasal(decisionId: nil, unitsPerHour: 6, duration: 300, automatic: false) { error in
            XCTAssertNotNil(error)
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = manager.rawState; read.signal() }
            XCTAssertEqual(read.wait(timeout: .now() + 1), .success, "Rejection completion must not hold deliveryLock")
        }
    }

    func testCachedScheduledStatusCannotEndAnAcknowledgedManualTemp() {
        let state = makeState()
        state.shortTempBasal = state.shortTempBasal?.confirmed(startedAt: start, observedAt: start)
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        var response = SynchronizePacketResponse(state: .active, activeAlarms: [])
        response.basal = basal(.STANDARD, at: start.addingTimeInterval(-100))
        StateSyncer.sync(syncResponse: response, state: state, pumpManager: manager, duringReconnect: false, fullSync: false)
        XCTAssertEqual(state.basalDose.type, .tempBasal)
        XCTAssertEqual(state.basalDose.decisionId, command)
        XCTAssertTrue(manager.hasManualTempBasal)
        response.basal = basal()
        StateSyncer.sync(syncResponse: response, state: state, pumpManager: manager, duringReconnect: true, fullSync: true)
        XCTAssertEqual(state.basalDose.type, .tempBasal)
        XCTAssertEqual(state.basalDose.decisionId, command)
    }

    func testLostSetReplyFollowedByLaterScheduledStatusRetainsUnknownAccounting() {
        let state = makeState()
        state.pendingTempBasal = state.basalDose
        state.basalDose = UnfinalizedDose(basalRate: 1, insulinType: nil, startDate: start.addingTimeInterval(-100))
        state.basalDeliveryUncertain = true
        StateSyncer.reconcileShortTempBasal(state: state, basal: basal(.STANDARD, at: start.addingTimeInterval(1800)),
                                           observedAt: start.addingTimeInterval(2400), fullSync: true)
        XCTAssertNotNil(state.pendingTempBasal, "Current scheduled status does not prove that the earlier command never ran")
        XCTAssertTrue(state.basalDeliveryUncertain)
        XCTAssertNotNil(state.shortTempBasal)
    }

    func testLostCancelReplyUsesPumpTransitionRatherThanReconnectTime() {
        let state = makeState()
        state.shortTempBasal = state.shortTempBasal?.confirmed(startedAt: start, observedAt: start)
        state.basalDeliveryUncertain = true
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        var response = SynchronizePacketResponse(state: .active, activeAlarms: [])
        response.basal = basal(.STANDARD, at: start.addingTimeInterval(300))
        StateSyncer.sync(syncResponse: response, state: state, pumpManager: manager, duringReconnect: true, fullSync: true)
        XCTAssertEqual(state.basalDose.type, .basal)
        XCTAssertEqual(state.basalDose.startDate.timeIntervalSince1970, start.addingTimeInterval(300).timeIntervalSince1970, accuracy: 1)
    }

    func testEditorDefaultsAndEstimatedTotalStayEditable() {
        let model = ManualTempBasalViewModel(pumpManager: nil, goBack: {})
        XCTAssertEqual(model.selectedRate, 30)
        XCTAssertEqual(model.selectedDuration, 60)
        XCTAssertEqual(model.estimatedUnits, "0.50 U")
        model.selectedDuration = 1500
        XCTAssertEqual(model.estimatedUnits, "12.50 U")
        model.selectedRate = 6
        XCTAssertEqual(model.estimatedUnits, "2.50 U")
        XCTAssertFalse(model.enacting)
    }

    func testConfiguredMaximumBelowEqualAndAboveDefaultControlsBothEditorAndDriver() {
        for maximum in [2.0, 6, 10, 30] {
            let state = makeState()
            state.pumpSN = Data([18, 187, 192, 52])
            state.shortTempBasal = nil
            state.basalDose = UnfinalizedDose(basalRate: 1, insulinType: nil, startDate: start)
            let manager = MedtrumPumpManager(state: state, bluetooth: nil)
            manager.syncDeliveryLimits(limits: DeliveryLimits(
                maximumBasalRate: LoopQuantity(unit: .internationalUnitsPerHour, doubleValue: maximum),
                maximumBolus: nil)) { result in
                if case .failure = result { XCTFail("Local manual limit must be recorded") }
            }
            let model = ManualTempBasalViewModel(pumpManager: manager, goBack: {})
            XCTAssertEqual(model.selectedRate, 30, "Keep the user's requested default visible")
            XCTAssertEqual(model.selectedDuration, 60)
            XCTAssertEqual(model.selectionWithinLimit, maximum >= 30)
            XCTAssertEqual(manager.manualTempBasalRateAllowed(6), maximum >= 6)
            XCTAssertEqual(MedtrumPumpState(rawValue: manager.rawState).manualBasalMaximum, maximum)
        }
    }

    func testImmediateCancelRequiresFreshPhysicalSegmentIdentity() {
        let state = makeState()
        state.shortTempBasal = state.shortTempBasal?.confirmed(startedAt: start, observedAt: start, sequence: 5)
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.shortTempBasalObservedSegment = basal()
        XCTAssertTrue(manager.manualTempBasalMatchesObservedSegment(startDate: start, rate: 6))
        manager.shortTempBasalObservedSegment = basal(at: start.addingTimeInterval(60))
        XCTAssertFalse(manager.manualTempBasalMatchesObservedSegment(startDate: start, rate: 6))
        manager.shortTempBasalObservedSegment = BasalData(type: .ABSOLUTE_TEMP, sequence: 6, patchId: 256, startTime: start, rate: 6, delivery: 0)
        XCTAssertFalse(manager.manualTempBasalMatchesObservedSegment(startDate: start, rate: 6))
        manager.shortTempBasalObservedSegment = basal(rate: 1)
        XCTAssertFalse(manager.manualTempBasalMatchesObservedSegment(startDate: start, rate: 6))
    }

    func testEditorUsesLivePumpModelRangeAndRejectsStaleUnsupportedSelection() {
        let state = makeState()
        state.shortTempBasal = nil
        state.manualBasalMaximum = 30
        state.pumpSN = Data([178, 52, 224, 60]) // synthetic MD8201
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        let model = ManualTempBasalViewModel(pumpManager: manager, goBack: {})
        XCTAssertEqual(state.model, "MD8201")
        XCTAssertEqual(model.allowedRates.last, 25)
        for rate in [10.0, 12, 25] {
            XCTAssertTrue(model.allowedRates.contains(rate))
            model.selectedRate = rate
            XCTAssertTrue(model.selectionWithinLimit)
        }
        model.selectedRate = 25.05
        XCTAssertFalse(model.selectionWithinLimit)
        state.pumpSN = Data([18, 187, 192, 52]) // synthetic MD8301
        XCTAssertEqual(state.model, "MD8301")
        XCTAssertEqual(model.allowedRates.last, 30)
        model.selectedRate = 30
        XCTAssertTrue(model.selectionWithinLimit)
        state.pumpSN = Data([178, 52, 224, 60])
        XCTAssertEqual(model.allowedRates.last, 25)
        XCTAssertFalse(model.selectionWithinLimit, "An old selection must not outlive the model capability")
    }

    func testManualRateValidationUsesModelAndConfiguredMaximumWithoutRaisingEither() {
        let state = makeState()
        state.shortTempBasal = nil
        state.pumpSN = Data([18, 187, 192, 52])
        state.manualBasalMaximum = 30
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        for rate in [10.0, 25, 30] { XCTAssertTrue(manager.manualTempBasalRateAllowed(rate)) }
        state.pumpSN = Data([178, 52, 224, 60])
        XCTAssertTrue(manager.manualTempBasalRateAllowed(25))
        XCTAssertFalse(manager.manualTempBasalRateAllowed(25.05))
        state.manualBasalMaximum = 12
        XCTAssertTrue(manager.manualTempBasalRateAllowed(12))
        XCTAssertFalse(manager.manualTempBasalRateAllowed(12.05))
        let model = ManualTempBasalViewModel(pumpManager: manager, goBack: {})
        model.selectedRate = 12
        model.selectedDuration = 3600
        XCTAssertTrue(model.selectionWithinLimit)
        XCTAssertEqual(model.estimatedUnits, "12.00 U")
        state.manualBasalMaximum = 6
        model.refreshStatus()
        XCTAssertFalse(model.selectionWithinLimit)
        XCTAssertFalse(manager.manualTempBasalRateAllowed(12))
        for rate in [0.0, -1, 5.03, Double.nan, Double.infinity] {
            model.selectedRate = rate
            XCTAssertFalse(model.selectionWithinLimit)
            XCTAssertFalse(manager.manualTempBasalRateAllowed(rate))
        }
        state.manualBasalMaximum = nil
        model.refreshStatus()
        model.selectedRate = 6
        XCTAssertFalse(model.selectionWithinLimit)
        XCTAssertFalse(manager.manualTempBasalRateAllowed(6))
        XCTAssertNil(state.manualBasalMaximum)
    }

    func testHighRateShortCommandReachesTransportRatherThanObsoleteTenUnitCap() {
        for rate in [10.0, 30] {
            let state = makeState()
            state.shortTempBasal = nil
            state.pumpSN = Data([18, 187, 192, 52])
            state.manualBasalMaximum = 30
            let manager = MedtrumPumpManager(state: state, bluetooth: nil)
            let completed = expectation(description: "Supported high rate passes configuration and reaches missing transport")
            manager.enactTempBasal(decisionId: nil, unitsPerHour: rate, duration: 300, automatic: false) { error in
                if let error, case .communication = error {} else {
                    XCTFail("Expected missing-transport failure, got \(String(describing: error))")
                }
                XCTAssertNil(state.shortTempBasal)
                XCTAssertNil(state.pendingTempBasal)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
        }
    }

    func testUnsupportedOrOverLimitShortRateIsRejectedBeforeConnecting() {
        for rate in [0.0, 12.05, 25.05, 30.05, 5.03, Double.nan, Double.infinity] {
            let state = makeState()
            state.shortTempBasal = nil
            state.pumpSN = Data([178, 52, 224, 60])
            state.manualBasalMaximum = 12
            let manager = MedtrumPumpManager(state: state, bluetooth: nil)
            let completed = expectation(description: "Invalid rate rejected before transport")
            manager.enactTempBasal(decisionId: nil, unitsPerHour: rate, duration: 300, automatic: false) { error in
                if let error, case .configuration = error {} else {
                    XCTFail("Expected configuration rejection, got \(String(describing: error))")
                }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
        }
    }

    func testFiveMinuteChoicesThroughOneHourPreserveNativeMinutesAndLongerOptions() {
        let model = ManualTempBasalViewModel(pumpManager: nil, goBack: {})
        XCTAssertEqual(Array(model.allowedDurations.prefix(21)),
                       [60, 120, 180, 240, 300, 360, 420, 480, 540, 600, 900, 1200, 1500, 1800, 2100, 2400, 2700, 3000, 3300, 3600, 5400])
        XCTAssertEqual(model.allowedDurations.last, 43200)
        XCTAssertEqual(model.allowedDurations.count, 42)
        for minutes in [35, 40, 45, 50, 55] {
            let duration = Double(minutes) * 60
            XCTAssertTrue(model.allowedDurations.contains(duration))
            let nativeDuration = MedtrumPumpManager.pumpTempBasalDuration(requested: duration, automatic: false)
            XCTAssertEqual(nativeDuration, duration)
            XCTAssertEqual(SetTempBasalPacket(rate: 6, duration: nativeDuration).getRequestBytes(),
                           Data([6, 120, 0, UInt8(minutes), 0]))
        }
        model.selectedDuration = 2100
        model.selectedRate = 6
        XCTAssertEqual(model.estimatedUnits, "3.50 U")
    }

    func testOneThroughFourMinuteCommandsStillUseNativeThirtyMinuteDelivery() {
        for minutes in [1, 2, 3, 4, 6, 7, 8, 9] {
            let duration = Double(minutes) * 60
            let state = makeState()
            state.shortTempBasal = nil
            let manager = MedtrumPumpManager(state: state, bluetooth: nil)
            let completed = expectation(description: "Short duration reaches missing transport")
            manager.enactTempBasal(decisionId: nil, unitsPerHour: 6, duration: duration, automatic: false) { error in
                if let error, case .communication = error {} else {
                    XCTFail("Expected missing-transport failure, got \(String(describing: error))")
                }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
            let native = MedtrumPumpManager.pumpTempBasalDuration(requested: duration, automatic: false)
            XCTAssertEqual(native, 1800)
            XCTAssertEqual(SetTempBasalPacket(rate: 6, duration: native).getRequestBytes(), Data([6, 120, 0, 30, 0]))
        }
    }

    func testNearZeroOffStepAndJustOverMaximumRatesAreRejectedBeforeTransport() {
        for (rate, maximum) in [(0.0000005, 0.0), (6.0000005, 30.0), (6.0, 5.9999995)] {
            let state = makeState()
            state.shortTempBasal = nil
            state.pumpSN = Data([18, 187, 192, 52])
            state.manualBasalMaximum = maximum
            let manager = MedtrumPumpManager(state: state, bluetooth: nil)
            let model = ManualTempBasalViewModel(pumpManager: manager, goBack: {})
            model.selectedRate = rate
            XCTAssertFalse(model.selectionWithinLimit)
            XCTAssertFalse(manager.manualTempBasalRateAllowed(rate))
            let completed = expectation(description: "Off-step or over-limit request is rejected before connecting")
            manager.enactTempBasal(decisionId: nil, unitsPerHour: rate, duration: 300, automatic: false) { error in
                if let error, case .configuration = error {} else {
                    XCTFail("Expected configuration rejection, got \(String(describing: error))")
                }
                XCTAssertNil(state.shortTempBasal)
                XCTAssertNil(state.pendingTempBasal)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 3)
        }
    }

    func testIntentAndPendingDoseAreCheckpointedTogether() throws {
        let state = makeState()
        let intent = state.shortTempBasal
        let requested = state.basalDose
        state.shortTempBasal = nil
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.persistPendingDelivery = {
            let raw = manager.rawState
            let saved = MedtrumPumpState(rawValue: raw)
            XCTAssertEqual(saved.shortTempBasal?.commandID, self.command)
            XCTAssertEqual(saved.pendingTempBasal?.decisionId, self.command)
            XCTAssertTrue(raw["awaitingBasalReply"] as? Bool == true)
            XCTAssertEqual(saved.pendingTempBasal?.estimatedEndDate, self.start.addingTimeInterval(1800))
        }
        try manager.checkpointBasal(requested: requested, shortIntent: intent)
    }

    func testRetiringUnacknowledgedSessionPreservesAccountingButStopsOldTimer() {
        let state = makeState()
        state.pendingTempBasal = state.basalDose
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.retireShortTempBasalIntent()
        XCTAssertNil(manager.shortTempBasalStatus)
        XCTAssertTrue(manager.hasUnresolvedShortTempBasalHistory)
        XCTAssertTrue(manager.status.deliveryIsUncertain)
        XCTAssertEqual(MedtrumPumpState(rawValue: manager.rawState).unresolvedShortTempBasals.count, 1)
    }

    func testManualFiveMinuteChoiceStillProducesNativeThirtyMinuteWireCommand() {
        let duration = MedtrumPumpManager.pumpTempBasalDuration(requested: 300, automatic: false)
        XCTAssertEqual(SetTempBasalPacket(rate: 6, duration: duration).getRequestBytes(), Data([6, 120, 0, 30, 0]))
        let automatic = MedtrumPumpManager.pumpTempBasalDuration(requested: 300, automatic: true)
        XCTAssertEqual(SetTempBasalPacket(rate: 6, duration: automatic).getRequestBytes(), Data([6, 120, 0, 5, 0]))
    }

    func testAutomaticCommandsCannotOverwriteManualTempBeforeHostNotificationArrives() {
        let state = makeState()
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        let rejectedBasal = expectation(description: "automatic basal is rejected by the manual guard")
        manager.enactGuardedAutomaticTempBasal(unitsPerHour: 1, duration: 1800, isValid: { true }) { error in
            if let error, case .configuration = error {} else { XCTFail("Manual delivery must be protected before connecting") }
            rejectedBasal.fulfill()
        }
        let rejectedSMB = expectation(description: "automatic bolus is rejected by the manual guard")
        manager.enactGuardedAutomaticBolus(units: 0.1, isValid: { true }) { error in
            if let error, case .configuration = error {} else { XCTFail("Manual delivery must block an in-flight automatic bolus decision") }
            rejectedSMB.fulfill()
        }
        wait(for: [rejectedBasal, rejectedSMB], timeout: 3)
    }

    func testRecoveredLaterStartRechecksAtItsDeadlineWithoutAddingRetryDelay() {
        let state = makeState()
        state.shortTempBasal = state.shortTempBasal?.confirmed(startedAt: start.addingTimeInterval(3), observedAt: start.addingTimeInterval(4))
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        manager.shortTempBasalNextAttempt = start.addingTimeInterval(330)
        XCTAssertTrue(manager.deferShortTempBasalUntilDeadline(command: command, now: start.addingTimeInterval(300)))
        XCTAssertEqual(manager.shortTempBasalNextAttempt, start.addingTimeInterval(303))
        XCTAssertFalse(state.shortTempBasal?.cancellationFailed ?? true)
        XCTAssertFalse(manager.deferShortTempBasalUntilDeadline(command: command, now: start.addingTimeInterval(303)))
    }
}

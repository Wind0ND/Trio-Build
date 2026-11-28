import Foundation
import LoopKit
import MedtrumLifecycleKit

public struct ShortTempBasalStatus {
    public let endDate: Date
    public let rate: Double
    public let minutes: Int
    public let estimatedUnits: Double
    public let awaitingConfirmation: Bool
    public let cancellationFailed: Bool
    public let accountingUnresolved: Bool
    public let nativeTiming: Bool
    public let alarmPrepared: Bool
    public let automatic: Bool
    public let correctionPulse: Bool
}

extension MedtrumPumpManager {
    func preparePulseContinuationForWrite(protectiveInterrupt: Bool, continuationOf: UUID?) {
        // A companion can itself be below the scheduled basal. It still needs
        // its parent for the final write validation; only an external request
        // supersedes that plan. Stale companion IDs are rejected by validation.
        if protectiveInterrupt, continuationOf == nil {
            deliveryLock.withLock { state.basalPulseContinuation = nil }
        }
    }

    public var hasActiveBasalPulse: Bool {
        deliveryLock.withLock { state.shortTempBasal?.pulseBudget != nil || state.basalPulseContinuation != nil }
    }

    public var lastBasalPulseAt: Date? {
        deliveryLock.withLock {
            guard state.lastBasalPulseSessionID == state.patchId,
                  state.lastBasalPulseSessionStart == state.patchActivatedAt else { return nil }
            return state.lastBasalPulseAt
        }
    }

    public var basalPulseCurrentRate: Double { deliveryLock.withLock { state.basalDose.value } }
    public var basalPulseScheduledRate: Double { deliveryLock.withLock { state.currentBaseBasalRate } }
    public var basalPulseCurrentMinutes: Int {
        deliveryLock.withLock {
            state.basalDose.type == .tempBasal ? max(0, Int(state.basalDose.estimatedEndDate.timeIntervalSinceNow / 60)) : 0
        }
    }
    public var basalPulseCurrentEnd: Date? {
        deliveryLock.withLock { state.basalDose.type == .tempBasal ? state.basalDose.estimatedEndDate : nil }
    }
    public var supportsAutomaticBasalPulse: Bool {
        let context = automaticBolusContext()
        return context.sessionID != nil && context.sessionStartedAt != nil &&
            deliveryLock.withLock({ !state.patchActivationIsProvisional && ["MD8301", "MD8201"].contains(state.model) }) &&
            (context.restrictionReason == "available" || context.restrictionReason == "basal_only")
    }
    public var shortTempAlarmScope: Data {
        deliveryLock.withLock {
            state.pumpSN + state.patchId + Data(String(state.patchActivatedAt?.timeIntervalSince1970 ?? -1).utf8)
        }
    }
    public func canRetireOrphanShortAlarm(_ command: UUID) -> Bool {
        deliveryLock.withLock {
            guard cachedPumpDataDate(at: Date()) != nil, !status.deliveryIsUncertain else { return false }
            return !shortTempAlarmRequests.contains { $0.commandID == command } &&
                state.pendingTempBasal?.decisionId != command && state.basalDose.decisionId != command
        }
    }
    func restorePreviousPulseTime(_ intent: MedtrumShortTempBasal?) {
        guard let intent, intent.pulseBudget != nil,
              state.lastBasalPulseSessionID == intent.sessionID,
              state.lastBasalPulseSessionStart == intent.sessionStartedAt else { return }
        state.lastBasalPulseAt = intent.previousPulseAt
        if intent.previousPulseAt == nil {
            state.lastBasalPulseSessionID = nil
            state.lastBasalPulseSessionStart = nil
        }
    }

    public var shortTempAlarmRequests: [(commandID: UUID, deadline: Date)] {
        deliveryLock.withLock {
            var intents = state.unresolvedShortTempBasals
            if let active = state.shortTempBasal { intents.append(active) }
            if let continuation = state.basalPulseContinuation { intents.append(continuation) }
            return intents.filter { $0.nativeTiming != true }.map { ($0.commandID, $0.targetEnd.addingTimeInterval(15)) }
        }
    }

    func shortTempRateAllowed(_ rate: Double, automatic: Bool) -> Bool {
        if !automatic { return manualTempBasalRateAllowed(rate) }
        return deliveryLock.withLock {
            guard let maximum = state.manualBasalMaximum else { return false }
            return rate.isFinite && rate >= 0 && rate <= maximum && supportedBasalRates.contains(rate)
        }
    }

    /// The only transport used here is the existing temp-basal set/cancel transaction.
    public func enactAutomaticBasalPulse(_ plan: MedtrumBasalPulsePlan, isValid: @escaping () -> Bool,
                                         completion: @escaping (PumpManagerError?) -> Void) {
        guard isValid(), automaticBasalPulseEnabled?() == true, supportsAutomaticBasalPulse, !hasActiveBasalPulse, !hasManualTempBasal,
              !status.deliveryIsUncertain, shortTempRateAllowed(plan.rate, automatic: true) else {
            completion(.configuration(MedtrumWriteError.contextChanged)); return
        }
        ensureConnectedAndActive { error in
            if let error { completion(.communication(error)); return }
            let template: MedtrumShortTempBasal? = self.deliveryLock.withLock {
                guard let sessionStart = self.state.patchActivatedAt, !self.state.patchSessionEnded,
                      isValid(), self.automaticBasalPulseEnabled?() == true,
                      var intent = MedtrumShortTempBasal(sessionID: self.state.patchId, sessionStartedAt: sessionStart,
                          commandID: UUID(), rate: plan.rate, minutes: plan.minutes, requestedAt: Date(), automatic: true) else { return nil }
                intent.nativeTiming = self.state.nativeShortTempBasalEnabled
                intent.pulseBudget = plan.extraUnits
                intent.alarmPrepared = intent.nativeTiming != true
                if plan.companionMinutes > 0 {
                    intent.pulseCompanionRate = plan.companionRate
                    intent.pulseCompanionEnd = plan.companionEnd ?? intent.requestedAt.addingTimeInterval(Double(plan.companionMinutes) * 60)
                }
                return intent
            }
            guard let template else {
                completion(.configuration(MedtrumWriteError.contextChanged)); return
            }
            if template.nativeTiming == true {
                self.enactTempBasal(decisionId: template.commandID, unitsPerHour: plan.rate,
                    duration: Double(plan.minutes) * 60, automatic: true, validation: isValid, shortIntent: template,
                    completion: completion)
                return
            }
            guard let arm = self.armShortTempBasalAlarm else {
                completion(.configuration(MedtrumBasalPulseError.alarmUnavailable)); return
            }
            arm(template.commandID, template.targetEnd.addingTimeInterval(15)) { armed in
                guard armed else {
                    self.retireShortTempBasalAlarm?(template.commandID)
                    completion(.configuration(MedtrumBasalPulseError.alarmUnavailable)); return
                }
                guard isValid() else {
                    self.retireShortTempBasalAlarm?(template.commandID)
                    completion(.configuration(MedtrumWriteError.contextChanged)); return
                }
                self.enactTempBasal(decisionId: template.commandID, unitsPerHour: plan.rate,
                    duration: Double(plan.minutes) * 60, automatic: true, validation: isValid, shortIntent: template) { error in
                    let mayHaveRun = self.deliveryLock.withLock {
                        self.state.shortTempBasal?.commandID == template.commandID ||
                            self.state.pendingTempBasal?.decisionId == template.commandID
                    }
                    if error != nil, !mayHaveRun { self.retireShortTempBasalAlarm?(template.commandID) }
                    completion(error)
                }
            }
        }
    }

    func finishEndedShortTempBasal(_ intent: MedtrumShortTempBasal) {
        // Always leave the host persistence queue outside deliveryLock.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do { try self.checkpointDelivery() }
            catch {
                if intent.nativeTiming == true {
                    self.pumpDelegate.notify { $0?.pumpManager(self, didError: .configuration(MedtrumWriteError.persistenceFailed)) }
                } else { self.emitAlert(alertType: .shortTempBasalCancellationFailed) }
                return
            }
            if intent.nativeTiming != true, self.deliveryLock.withLock({ self.state.basalPulseContinuation?.commandID != intent.commandID }) {
                self.retireShortTempBasalAlarm?(intent.commandID)
            }
            self.servicePulseCompanion()
        }
    }

    func servicePulseCompanion() {
        let pending: MedtrumShortTempBasal? = deliveryLock.withLock {
            guard persistPendingDelivery != nil, automaticBasalPulseEnabled != nil, isCurrentBasalPulsePump != nil,
                  !pulseContinuationInFlight, !submittingDelivery, ProcessInfo.processInfo.systemUptime >= pulseContinuationNextAttemptUptime, state.shortTempBasal == nil,
                  !state.basalDeliveryUncertain, !state.bolusDeliveryUncertain,
                  let intent = state.basalPulseContinuation else { return nil }
            pulseContinuationInFlight = true
            pulseContinuationNextAttemptUptime = ProcessInfo.processInfo.systemUptime + 30
            return intent
        }
        guard let pending else { return }
        guard let maximum = manualTempBasalMaximum else {
            deliveryLock.withLock { pulseContinuationInFlight = false }
            if pending.nativeTiming == true { reportNativeTempBasalFailure(command: pending.commandID) }
            else { reportBasalPulseCompanionFailure?(pending.commandID) }
            return
        }
        let companionRate = pending.pulseCompanionRate.flatMap { proposed in
            supportedBasalRates.filter { $0 <= min(proposed, maximum) }.max()
        }
        let valid = { [weak self] in
            guard let self else { return false }
            return self.deliveryLock.withLock {
                self.isCurrentBasalPulsePump?() == true &&
                    (self.automaticBasalPulseEnabled?() == true || (companionRate ?? .infinity) <= self.state.currentBaseBasalRate) && !self.hasManualTempBasal &&
                    self.state.patchId == pending.sessionID && self.state.patchActivatedAt == pending.sessionStartedAt &&
                    self.state.basalPulseContinuation?.commandID == pending.commandID &&
                    !self.state.patchSessionEnded && !self.status.deliveryIsUncertain
            }
        }
        guard valid(), let end = pending.pulseCompanionEnd, let rate = companionRate,
              end > Date(), !pending.clockMappingChanged(at: Date()), shortTempRateAllowed(rate, automatic: true),
              rate <= basalPulseCurrentRate || Date().timeIntervalSince(pending.requestedAt) <= 4.5 * 60 else {
            deliveryLock.withLock { state.basalPulseContinuation = nil; pulseContinuationInFlight = false }
            finishEndedShortTempBasal(pending)
            return
        }
        let remaining = end.timeIntervalSinceNow
        // Never extend an above-profile companion when converting to whole pump minutes.
        // A protective reduction may last the rounded-up minute instead of ending early.
        let duration = pending.nativeTiming == true && rate > basalPulseScheduledRate
            ? floor(remaining / 60) * 60 : ceil(remaining / 60) * 60
        guard duration >= 60 else {
            deliveryLock.withLock { state.basalPulseContinuation = nil; pulseContinuationInFlight = false }
            finishEndedShortTempBasal(pending)
            return
        }
        let callback: (PumpManagerError?) -> Void = { [weak self] error in
            guard let self else { return }
            self.deliveryLock.withLock {
                self.pulseContinuationInFlight = false
                if error == nil, self.state.basalPulseContinuation?.commandID == pending.commandID {
                    self.state.basalPulseContinuation = nil
                }
            }
            if error == nil { self.finishEndedShortTempBasal(pending) }
            else if pending.nativeTiming == true { self.reportNativeTempBasalFailure(command: pending.commandID) }
            else if let report = self.reportBasalPulseCompanionFailure { report(pending.commandID) }
            else { self.emitAlert(alertType: .basalPulseContinuationFailed) }
        }
        guard var template = MedtrumShortTempBasal(sessionID: pending.sessionID, sessionStartedAt: pending.sessionStartedAt,
            commandID: UUID(), rate: rate, minutes: Int(duration / 60), requestedAt: Date(), automatic: true) else {
            callback(.configuration(MedtrumWriteError.contextChanged)); return
        }
        template.nativeTiming = pending.nativeTiming
        template.absoluteEnd = end
        template.nativeCompanionRoundsUp = pending.nativeTiming == true ? rate <= basalPulseScheduledRate : nil
        template.pulseParentCommandID = pending.commandID
        template.alarmPrepared = template.nativeTiming != true
        guard template.isValid else { callback(.configuration(MedtrumWriteError.contextChanged)); return }
        if template.nativeTiming == true {
            enactTempBasal(decisionId: template.commandID, unitsPerHour: rate, duration: duration,
                automatic: true, validation: valid, shortIntent: template, continuationOf: pending.commandID,
                completion: callback)
            return
        }
        guard let arm = armShortTempBasalAlarm else { callback(.configuration(MedtrumWriteError.contextChanged)); return }
        arm(template.commandID, end.addingTimeInterval(15)) { [weak self] armed in
            guard let self else { return }
            guard armed, valid() else {
                self.retireShortTempBasalAlarm?(template.commandID)
                callback(.configuration(MedtrumWriteError.contextChanged)); return
            }
            self.enactTempBasal(decisionId: template.commandID, unitsPerHour: rate, duration: duration,
                automatic: true, validation: valid, shortIntent: template, continuationOf: pending.commandID) { error in
                    if error != nil, self.deliveryLock.withLock({ self.state.shortTempBasal?.commandID != template.commandID }) {
                        self.retireShortTempBasalAlarm?(template.commandID)
                    }
                    callback(error)
                }
        }
    }

    static func pumpTempBasalDuration(requested: TimeInterval, automatic: Bool, nativeTiming: Bool = false) -> TimeInterval {
        !nativeTiming && !automatic && requested > 0 && requested < .minutes(30) ? .minutes(30) : requested
    }

    /// Ordinary unknown-delivery reporting, never the legacy cancellation AlarmKit callback.
    func reportNativeTempBasalFailure(command: UUID) {
        let current = deliveryLock.withLock {
            guard state.shortTempBasal?.commandID == command || state.basalPulseContinuation?.commandID == command else { return false }
            state.basalDeliveryUncertain = true
            if state.shortTempBasal?.commandID == command { state.shortTempBasal?.accountingUnresolved = true }
            notifyStateDidChange()
            return true
        }
        guard current else { return }
        emitShortTempBasalDiagnostic("failed")
        pumpDelegate.notify { $0?.pumpManager(self, didError: .uncertainDelivery) }
    }
    public var shortTempBasalStatus: ShortTempBasalStatus? {
        deliveryLock.withLock {
            guard let intent = state.shortTempBasal else { return nil }
            return ShortTempBasalStatus(endDate: intent.targetEnd, rate: intent.rate, minutes: intent.minutes,
                estimatedUnits: intent.estimatedUnits,
                awaitingConfirmation: intent.confirmedStart == nil || state.basalDeliveryUncertain,
                cancellationFailed: intent.cancellationFailed, accountingUnresolved: intent.accountingUnresolved,
                nativeTiming: intent.nativeTiming == true, alarmPrepared: intent.alarmPrepared == true, automatic: intent.automaticPulse == true,
                correctionPulse: intent.pulseBudget != nil)
        }
    }

    public var hasManualTempBasal: Bool {
        deliveryLock.withLock {
            state.shortTempBasal.map { $0.automaticPulse != true } == true || (state.basalDose.type == .tempBasal && !state.basalDose.automatic)
        }
    }

    public var manualTempBasalMaximum: Double? { deliveryLock.withLock { state.manualBasalMaximum } }
    public var hasUnresolvedShortTempBasalHistory: Bool { deliveryLock.withLock { !state.unresolvedShortTempBasals.isEmpty } }

    func manualTempBasalRateAllowed(_ rate: Double) -> Bool {
        deliveryLock.withLock {
            guard let maximum = state.manualBasalMaximum else { return false }
            return rate.isFinite && rate > 0 && rate <= maximum && supportedBasalRates.contains(rate)
        }
    }

    func retireShortTempBasalIntent() {
        deliveryLock.withLock {
            StateSyncer.retireShortTempBasal(state: state)
            shortTempBasalObservedSegment = nil
            shortTempBasalLastVerifiedSync = .distantPast
        }
    }

    func startShortTempBasalMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.serviceShortTempBasalDeadline() }
        shortTempBasalTimer = timer
        timer.resume()
    }

    /// A timer is only an opportunity to run. The persisted deadline survives app suspension.
    func serviceShortTempBasalDeadline() {
        servicePulseCompanion()
        let shifted: UUID? = deliveryLock.withLock {
            guard let intent = state.shortTempBasal, intent.nativeTiming != true, intent.clockMappingChanged(at: Date()),
                  !shortTempClockAlerted.contains(intent.commandID) else { return nil }
            shortTempClockAlerted = [intent.commandID]
            return intent.commandID
        }
        if let shifted { reportShortTempBasalFailure?(shifted) }
        let command: UUID? = deliveryLock.withLock {
            guard persistPendingDelivery != nil, shortTempBasalMonitoringEnabled, !state.patchSessionEnded,
                  bluetooth != nil, let intent = state.shortTempBasal,
                  (intent.nativeTiming == true ? Date() >= intent.targetEnd.addingTimeInterval(5) :
                    intent.deadlineHasPassed(at: Date()) || intent.clockMappingChanged(at: Date())),
                  ProcessInfo.processInfo.systemUptime >= shortTempBasalNextAttemptUptime,
                  !shortTempBasalCheckInFlight else { return nil }
            shortTempBasalCheckInFlight = true
            shortTempBasalNextAttempt = Date().addingTimeInterval(30)
            shortTempBasalNextAttemptUptime = ProcessInfo.processInfo.systemUptime + 30
            return intent.commandID
        }
        guard let command else { return }
        let syncStarted = Date()
        syncPumpData { [weak self] syncedAt in
            guard let self else { return }
            guard syncedAt != nil, self.deliveryLock.withLock({ self.shortTempBasalLastVerifiedSync >= syncStarted }) else {
                self.finishShortTempBasalAttempt(command: command, error: true); return
            }
            let stillCurrent = self.deliveryLock.withLock { self.state.shortTempBasal?.commandID == command }
            guard stillCurrent else {
                self.emitShortTempBasalDiagnostic("invalidated")
                self.finishShortTempBasalAttempt(command: command, error: false); return
            }
            if self.deferShortTempBasalUntilDeadline(command: command, now: Date()) {
                self.finishShortTempBasalAttempt(command: command, error: false); return
            }
            if self.deliveryLock.withLock({ self.state.shortTempBasal?.nativeTiming == true }) {
                // A native timer is observed, never cancelled by the phone deadline.
                self.finishShortTempBasalAttempt(command: command, error: true)
                return
            }
            let canCancel = self.deliveryLock.withLock { self.shortTempBasalCanCancel(command: command, at: Date()) }
            guard canCancel else { self.finishShortTempBasalAttempt(command: command, error: true); return }
            self.enactTempBasal(decisionId: nil, unitsPerHour: 0, duration: 0, automatic: false,
                validation: { [weak self] in
                    guard let self else { return false }
                    return self.deliveryLock.withLock { self.shortTempBasalCanCancel(command: command, at: Date()) }
                }, deadlineCancellation: command, completion: { [weak self] error in
                    if error == nil { self?.emitShortTempBasalDiagnostic("cancelled") }
                    self?.finishShortTempBasalAttempt(command: command, error: error != nil)
                })
        }
    }

    /// A recovered pump start may move the real deadline past the initial pending-intent check.
    func deferShortTempBasalUntilDeadline(command: UUID, now: Date) -> Bool {
        deliveryLock.withLock {
            guard let intent = state.shortTempBasal, intent.commandID == command,
                  intent.confirmedStart != nil, !intent.accountingUnresolved,
                  !intent.deadlineHasPassed(at: now), !intent.clockMappingChanged(at: now) else { return false }
            shortTempBasalNextAttempt = min(shortTempBasalNextAttempt, intent.targetEnd)
            shortTempBasalNextAttemptUptime = min(shortTempBasalNextAttemptUptime,
                ProcessInfo.processInfo.systemUptime + max(0, intent.targetEnd.timeIntervalSince(now)))
            return true
        }
    }

    func shortTempBasalCanCancel(command: UUID, at now: Date, requiresDeadline: Bool = true) -> Bool {
        guard let intent = state.shortTempBasal, intent.commandID == command,
              (!requiresDeadline || intent.nativeTiming != true),
              !state.patchSessionEnded, state.basalState == .tempBasal,
              !state.basalDeliveryUncertain, !state.bolusDeliveryUncertain,
              shortTempBasalMonitoringEnabled, state.pumpState.isDelivering, state.bolusState == .noBolus,
              let observed = shortTempBasalObservedSegment,
              observed.type == .ABSOLUTE_TEMP, observed.patchId == Double(state.patchId.toUInt64()),
              abs(observed.rate - intent.rate) < 0.001,
              intent.pumpStart.map({ abs(observed.startTime.timeIntervalSince($0)) < 1 }) ?? false,
              intent.segmentSequence.map({ $0 == observed.sequence }) ?? true else { return false }
        let dose = state.basalDose
        return dose.type == .tempBasal && intent.canCancel(sessionID: state.patchId,
            sessionStartedAt: state.patchActivatedAt, commandID: dose.decisionId, startDate: dose.startDate,
            rate: dose.value, automatic: dose.automatic, now: now, requiresDeadline: requiresDeadline)
    }

    private func finishShortTempBasalAttempt(command: UUID, error: Bool) {
        if deliveryLock.withLock({ state.shortTempBasal?.commandID == command && state.shortTempBasal?.nativeTiming == true }) {
            deliveryLock.withLock { shortTempBasalCheckInFlight = false }
            if error { reportNativeTempBasalFailure(command: command) }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                do { try self.checkpointDelivery() }
                catch { self.pumpDelegate.notify { $0?.pumpManager(self, didError: .configuration(MedtrumWriteError.persistenceFailed)) } }
            }
            return
        }
        let shouldAlert = deliveryLock.withLock {
            shortTempBasalCheckInFlight = false
            guard error, state.shortTempBasal?.commandID == command,
                  state.shortTempBasal?.cancellationFailed == false else { return false }
            state.shortTempBasal?.cancellationFailed = true
            notifyStateDidChange()
            return true
        }
        if shouldAlert {
            emitShortTempBasalDiagnostic("failed")
            if let reportShortTempBasalFailure { reportShortTempBasalFailure(command) }
            else { emitAlert(alertType: .shortTempBasalCancellationFailed) }
        }
        // Host persistence reads rawState on its own queue: never wait with deliveryLock held.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do { try self.checkpointDelivery() } catch {
                self.pumpDelegate.notify { $0?.pumpManager(self, didError: .configuration(MedtrumWriteError.persistenceFailed)) }
            }
        }
    }

    /// Immediate user cancellation also revalidates the original dose after connecting and queueing.
    public func cancelCurrentManualTempBasal(completion: @escaping (PumpManagerError?) -> Void) {
        let original = deliveryLock.withLock { (state.patchId, state.patchActivatedAt, state.basalDose.startDate, state.basalDose.decisionId, state.basalDose.value, state.basalDose.automatic) }
        let syncStarted = Date()
        syncPumpData { [weak self] syncedAt in
            guard let self else { return }
            guard syncedAt != nil, self.deliveryLock.withLock({ self.shortTempBasalLastVerifiedSync >= syncStarted }) else {
                completion(.communication(MedtrumWriteError.noManager)); return
            }
            let observed = self.deliveryLock.withLock { self.shortTempBasalObservedSegment }
            let valid: () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.deliveryLock.withLock {
                    self.shortTempBasalMonitoringEnabled && !self.state.patchSessionEnded && self.state.patchId == original.0 && self.state.patchActivatedAt == original.1 &&
                        !self.state.basalDeliveryUncertain && !self.state.bolusDeliveryUncertain && self.state.pumpState.isDelivering &&
                        self.state.basalDose.type == .tempBasal && self.state.basalDose.automatic == original.5 &&
                        self.state.basalDose.startDate == original.2 && self.state.basalDose.decisionId == original.3 &&
                        self.manualTempBasalMatchesObservedSegment(startDate: original.2, rate: original.4) &&
                        observed.map { self.shortTempBasalObservedSegment?.sameSegment(as: $0) == true } == true
                }
            }
            guard valid() else { completion(.configuration(MedtrumWriteError.contextChanged)); return }
            self.enactTempBasal(decisionId: nil, unitsPerHour: 0, duration: 0, automatic: false, validation: valid) { error in
                self.emitShortTempBasalDiagnostic(error == nil ? "cancelled" : "failed")
                completion(error)
            }
        }
    }

    func manualTempBasalMatchesObservedSegment(startDate: Date, rate: Double) -> Bool {
        guard let observed = shortTempBasalObservedSegment, observed.type == .ABSOLUTE_TEMP,
              observed.patchId == Double(state.patchId.toUInt64()), abs(observed.rate - rate) < 0.001 else { return false }
        if let intent = state.shortTempBasal, let pumpStart = intent.pumpStart,
           intent.commandID == state.basalDose.decisionId {
            return abs(observed.startTime.timeIntervalSince(pumpStart)) < 1 &&
                (intent.segmentSequence.map { $0 == observed.sequence } ?? true)
        }
        return abs(state.localDate(forPumpDate: observed.startTime).timeIntervalSince(startDate)) < 1
    }

    func emitShortTempBasalDiagnostic(_ outcome: String) {
        NotificationCenter.default.post(name: Notification.Name("com.trio.diagnostics.event"), object: nil,
            userInfo: ["schema": 1, "feature": "medtrum", "stage": "short_temp", "outcome": outcome])
    }
}

extension StateSyncer {
    /// Apply this only to a detached candidate after native proof; the host saves it before unlocking.
    static func resolveAutomaticShortCandidate(state: MedtrumPumpState, request: UnfinalizedDose?,
        activeDose: UnfinalizedDose?, executed: Bool, actualStart: Date?, actualEnd: Date?) -> MedtrumShortTempBasal? {
        guard let intent = state.shortTempBasal, intent.automaticPulse == true,
              request?.decisionId == intent.commandID, request?.automatic == true else { return nil }
        if activeDose?.type == .tempBasal {
            state.shortTempBasal?.accountingUnresolved = false
            if intent.pulseBudget != nil { state.lastBasalPulseAt = actualStart ?? activeDose?.startDate }
            return nil
        }
        state.shortTempBasal = nil
        if executed {
            if intent.pulseBudget != nil { state.lastBasalPulseAt = actualStart ?? intent.confirmedStart ?? intent.requestedAt }
            if let parent = intent.pulseParentCommandID, state.basalPulseContinuation?.commandID == parent {
                state.basalPulseContinuation = nil
            } else if let actualEnd {
                rememberPulseCompanion(state: state, ended: intent, at: actualEnd)
            }
        } else if intent.pulseBudget != nil {
            state.lastBasalPulseAt = intent.previousPulseAt
            state.lastBasalPulseSessionID = intent.previousPulseAt == nil ? nil : intent.sessionID
            state.lastBasalPulseSessionStart = intent.previousPulseAt == nil ? nil : intent.sessionStartedAt
        }
        return intent
    }
    static func rememberPulseCompanion(state: MedtrumPumpState, ended intent: MedtrumShortTempBasal, at end: Date) {
        guard intent.automaticPulse == true, intent.pulseBudget != nil,
              end >= intent.targetEnd.addingTimeInterval(-2),
              intent.sessionID == state.patchId, intent.sessionStartedAt == state.patchActivatedAt,
              let deadline = intent.pulseCompanionEnd, deadline > end, intent.pulseCompanionRate != nil else { return }
        state.basalPulseContinuation = intent
    }
    static func retireShortTempBasal(state: MedtrumPumpState) {
        guard var intent = state.shortTempBasal else { return }
        if intent.accountingUnresolved || state.pendingTempBasal?.decisionId == intent.commandID {
            intent.accountingUnresolved = true
            state.unresolvedShortTempBasals.append(intent)
            state.unresolvedShortTempBasals = Array(state.unresolvedShortTempBasals.suffix(20))
        }
        state.shortTempBasal = nil
    }

    /// Only an authoritative full status may replace or complete a persisted short-temp intent.
    @discardableResult
    static func reconcileShortTempBasal(state: MedtrumPumpState, basal: BasalData, observedAt: Date, fullSync: Bool) -> Bool {
        state.shortTempBasalTransitionTime = nil
        guard let intent = state.shortTempBasal else { return true }
        guard !state.awaitingBasalReply, fullSync else { return false }
        guard state.patchId == intent.sessionID, state.patchActivatedAt == intent.sessionStartedAt, !state.patchSessionEnded else {
            retireShortTempBasal(state: state)
            return false
        }
        if basal.type == .STANDARD || basal.type.isSuspendedByPump() {
            guard state.pendingTempBasal?.decisionId != intent.commandID,
                  let transition = intent.confirmedEnd(pumpEnd: basal.startTime, observedAt: observedAt,
                    clockOffset: state.pumpTime.timeIntervalSince(state.pumpTimeSyncedAt)),
                  state.basalDose.decisionId == intent.commandID else {
                state.shortTempBasal?.accountingUnresolved = true
                state.basalDeliveryUncertain = true
                return intent.automaticPulse == true && state.pendingTempBasal?.decisionId == intent.commandID
            }
            state.shortTempBasalTransitionTime = transition
            state.basalDeliveryUncertain = false
            rememberPulseCompanion(state: state, ended: intent, at: transition)
            state.shortTempBasal = nil
            return true
        }
        guard basal.type == .ABSOLUTE_TEMP, abs(basal.rate - intent.rate) < 0.001,
              basal.patchId == Double(state.patchId.toUInt64()) else {
            state.shortTempBasal?.accountingUnresolved = true
            state.basalDeliveryUncertain = true
            retireShortTempBasal(state: state)
            return false
        }
        if let pumpStart = intent.pumpStart, abs(basal.startTime.timeIntervalSince(pumpStart)) >= 1 ||
            (intent.segmentSequence.map { $0 != basal.sequence } ?? false) {
            state.shortTempBasal?.accountingUnresolved = true
            state.basalDeliveryUncertain = true
            retireShortTempBasal(state: state)
            return false
        }
        if intent.confirmedStart != nil, intent.clockMappingChanged(at: observedAt) {
            // Segment ownership survives a phone clock jump. Retain its original mapping for cancellation;
            // never manufacture a new history timestamp from the changed wall clock.
            return true
        }
        let offset = intent.confirmedStart.map { basal.startTime.timeIntervalSince($0) }
            ?? state.pumpTime.timeIntervalSince(state.pumpTimeSyncedAt)
        guard let confirmed = intent.confirmed(startedAt: basal.startTime, observedAt: observedAt, clockOffset: offset,
                                               sequence: basal.sequence, acknowledged: intent.confirmedStart != nil),
              let localStart = confirmed.confirmedStart else {
            state.shortTempBasal?.accountingUnresolved = true
            state.basalDeliveryUncertain = true
            return false
        }
        state.shortTempBasal = confirmed
        if confirmed.pulseBudget != nil {
            state.lastBasalPulseAt = localStart
            state.lastBasalPulseSessionID = confirmed.sessionID
            state.lastBasalPulseSessionStart = confirmed.sessionStartedAt
        }
        if let parent = intent.pulseParentCommandID, state.basalPulseContinuation?.commandID == parent {
            state.basalPulseContinuation = nil
        }
        state.basalDose = UnfinalizedDose(decisionId: intent.commandID, tempRate: intent.rate, duration: intent.nativeDuration,
            insulinType: state.insulinType, automatic: intent.automaticPulse == true, startDate: localStart)
        if state.pendingTempBasal?.decisionId == intent.commandID {
            if intent.automaticPulse == true { return true } // Atomic native recovery commits the pending request.
            state.pendingTempBasal = nil
            state.basalDeliveryUncertain = false
        }
        return true
    }
}

extension BasalData {
    func sameSegment(as other: BasalData) -> Bool {
        type == other.type && sequence == other.sequence && patchId == other.patchId &&
            startTime == other.startTime && abs(rate - other.rate) < 0.001
    }
}

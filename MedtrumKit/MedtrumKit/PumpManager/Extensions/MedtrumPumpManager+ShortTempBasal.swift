import Foundation
import LoopKit

public struct ShortTempBasalStatus {
    public let endDate: Date
    public let rate: Double
    public let minutes: Int
    public let estimatedUnits: Double
    public let awaitingConfirmation: Bool
    public let cancellationFailed: Bool
    public let accountingUnresolved: Bool
}

extension MedtrumPumpManager {
    static func pumpTempBasalDuration(requested: TimeInterval, automatic: Bool) -> TimeInterval {
        !automatic && requested > 0 && requested < .minutes(30) ? .minutes(30) : requested
    }
    public var shortTempBasalStatus: ShortTempBasalStatus? {
        deliveryLock.withLock {
            guard let intent = state.shortTempBasal else { return nil }
            return ShortTempBasalStatus(endDate: intent.targetEnd, rate: intent.rate, minutes: intent.minutes,
                estimatedUnits: intent.estimatedUnits,
                awaitingConfirmation: intent.confirmedStart == nil || state.basalDeliveryUncertain,
                cancellationFailed: intent.cancellationFailed, accountingUnresolved: intent.accountingUnresolved)
        }
    }

    public var hasManualTempBasal: Bool {
        deliveryLock.withLock {
            state.shortTempBasal != nil || (state.basalDose.type == .tempBasal && !state.basalDose.automatic)
        }
    }

    public var manualTempBasalMaximum: Double? { deliveryLock.withLock { state.manualBasalMaximum } }
    public var hasUnresolvedShortTempBasalHistory: Bool { deliveryLock.withLock { !state.unresolvedShortTempBasals.isEmpty } }

    func manualTempBasalRateAllowed(_ rate: Double) -> Bool {
        deliveryLock.withLock {
            guard let maximum = state.manualBasalMaximum else { return false }
            return rate.isFinite && rate > 0 && rate <= maximum + 0.000001 &&
                supportedBasalRates.contains { abs($0 - rate) < 0.000001 }
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
        let command: UUID? = deliveryLock.withLock {
            guard shortTempBasalMonitoringEnabled, !state.patchSessionEnded,
                  bluetooth != nil, let intent = state.shortTempBasal,
                  Date() >= intent.targetEnd, Date() >= shortTempBasalNextAttempt,
                  !shortTempBasalCheckInFlight else { return nil }
            shortTempBasalCheckInFlight = true
            shortTempBasalNextAttempt = Date().addingTimeInterval(30)
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
            let canCancel = self.deliveryLock.withLock { self.shortTempBasalCanCancel(command: command, at: Date()) }
            guard canCancel else { self.finishShortTempBasalAttempt(command: command, error: true); return }
            self.enactTempBasal(decisionId: nil, unitsPerHour: 0, duration: 0, automatic: false,
                validation: { [weak self] in
                    guard let self else { return false }
                    return self.deliveryLock.withLock { self.shortTempBasalCanCancel(command: command, at: Date()) }
                }, completion: { [weak self] error in
                    if error == nil { self?.emitShortTempBasalDiagnostic("cancelled") }
                    self?.finishShortTempBasalAttempt(command: command, error: error != nil)
                })
        }
    }

    /// A recovered pump start may move the real deadline past the initial pending-intent check.
    func deferShortTempBasalUntilDeadline(command: UUID, now: Date) -> Bool {
        deliveryLock.withLock {
            guard let intent = state.shortTempBasal, intent.commandID == command,
                  intent.confirmedStart != nil, !intent.accountingUnresolved, intent.targetEnd > now else { return false }
            shortTempBasalNextAttempt = min(shortTempBasalNextAttempt, intent.targetEnd)
            return true
        }
    }

    private func shortTempBasalCanCancel(command: UUID, at now: Date) -> Bool {
        guard let intent = state.shortTempBasal, intent.commandID == command,
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
            rate: dose.value, automatic: dose.automatic, now: now)
    }

    private func finishShortTempBasalAttempt(command: UUID, error: Bool) {
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
            emitAlert(alertType: .shortTempBasalCancellationFailed)
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
        let original = deliveryLock.withLock { (state.patchId, state.patchActivatedAt, state.basalDose.startDate, state.basalDose.decisionId, state.basalDose.value) }
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
                        self.state.basalDose.type == .tempBasal && !self.state.basalDose.automatic &&
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
                return false
            }
            state.shortTempBasalTransitionTime = transition
            state.basalDeliveryUncertain = false
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
        state.basalDose = UnfinalizedDose(decisionId: intent.commandID, tempRate: intent.rate, duration: .minutes(30),
            insulinType: state.insulinType, automatic: false, startDate: localStart)
        if state.pendingTempBasal?.decisionId == intent.commandID {
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

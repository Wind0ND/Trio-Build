import Foundation
import LoopKit

public struct ShortTempBasalStatus {
    public let endDate: Date
    public let rate: Double
    public let minutes: Int
    public let estimatedUnits: Double
    public let awaitingConfirmation: Bool
    public let cancellationFailed: Bool
}

extension MedtrumPumpManager {
    public var shortTempBasalStatus: ShortTempBasalStatus? {
        deliveryLock.withLock {
            guard let intent = state.shortTempBasal else { return nil }
            return ShortTempBasalStatus(endDate: intent.targetEnd, rate: intent.rate, minutes: intent.minutes,
                estimatedUnits: intent.estimatedUnits,
                awaitingConfirmation: intent.confirmedStart == nil || state.basalDeliveryUncertain,
                cancellationFailed: intent.cancellationFailed)
        }
    }

    public var hasManualTempBasal: Bool {
        deliveryLock.withLock {
            state.shortTempBasal != nil || (state.basalDose.type == .tempBasal && !state.basalDose.automatic)
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
            guard bluetooth != nil, let intent = state.shortTempBasal,
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

    private func shortTempBasalCanCancel(command: UUID, at now: Date) -> Bool {
        guard let intent = state.shortTempBasal, intent.commandID == command,
              !state.patchSessionEnded, state.basalState == .tempBasal,
              !state.basalDeliveryUncertain, !state.bolusDeliveryUncertain,
              state.pumpState.isDelivering, state.bolusState == .noBolus else { return false }
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
        do { try checkpointDelivery() } catch { pumpDelegate.notify { $0?.pumpManager(self, didError: .configuration(MedtrumWriteError.persistenceFailed)) } }
    }

    /// Immediate user cancellation also revalidates the original dose after connecting and queueing.
    public func cancelCurrentManualTempBasal(completion: @escaping (PumpManagerError?) -> Void) {
        let original = deliveryLock.withLock { (state.patchId, state.patchActivatedAt, state.basalDose.startDate, state.basalDose.decisionId) }
        let syncStarted = Date()
        syncPumpData { [weak self] syncedAt in
            guard let self else { return }
            guard syncedAt != nil, self.deliveryLock.withLock({ self.shortTempBasalLastVerifiedSync >= syncStarted }) else {
                completion(.communication(MedtrumWriteError.noManager)); return
            }
            let valid: () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.deliveryLock.withLock {
                    !self.state.patchSessionEnded && self.state.patchId == original.0 && self.state.patchActivatedAt == original.1 &&
                        !self.state.basalDeliveryUncertain && !self.state.bolusDeliveryUncertain && self.state.pumpState.isDelivering &&
                        self.state.basalDose.type == .tempBasal && !self.state.basalDose.automatic &&
                        self.state.basalDose.startDate == original.2 && self.state.basalDose.decisionId == original.3
                }
            }
            guard valid() else { completion(.configuration(MedtrumWriteError.contextChanged)); return }
            self.enactTempBasal(decisionId: nil, unitsPerHour: 0, duration: 0, automatic: false, validation: valid) { error in
                self.emitShortTempBasalDiagnostic(error == nil ? "cancelled" : "failed")
                completion(error)
            }
        }
    }

    func emitShortTempBasalDiagnostic(_ outcome: String) {
        NotificationCenter.default.post(name: Notification.Name("com.trio.diagnostics.event"), object: nil,
            userInfo: ["schema": 1, "feature": "medtrum", "stage": "short_temp", "outcome": outcome])
    }
}

extension StateSyncer {
    /// Only an authoritative full status may replace or complete a persisted short-temp intent.
    static func reconcileShortTempBasal(state: MedtrumPumpState, basal: BasalData, observedAt: Date, fullSync: Bool) {
        guard let intent = state.shortTempBasal, !state.awaitingBasalReply else { return }
        guard state.patchId == intent.sessionID, state.patchActivatedAt == intent.sessionStartedAt, !state.patchSessionEnded else {
            state.shortTempBasal = nil
            return
        }
        guard fullSync else { return }
        if basal.type == .STANDARD || basal.type.isSuspendedByPump() {
            if state.pendingTempBasal?.decisionId == intent.commandID {
                state.pendingTempBasal = nil
                state.basalDeliveryUncertain = false
            }
            state.shortTempBasal = nil
            return
        }
        guard basal.type == .ABSOLUTE_TEMP, abs(basal.rate - intent.rate) < 0.001,
              basal.patchId == Double(state.patchId.toUInt64()) else {
            state.shortTempBasal = nil
            return
        }
        if let confirmed = intent.confirmedStart {
            if abs(basal.startTime.timeIntervalSince(confirmed)) >= 1 { state.shortTempBasal = nil }
        } else if let confirmed = intent.confirmed(startedAt: basal.startTime, observedAt: observedAt) {
            state.shortTempBasal = confirmed
            // A successful command reply may have been saved with the local request time.
            if state.basalDose.decisionId == intent.commandID {
                state.basalDose = UnfinalizedDose(decisionId: intent.commandID, tempRate: intent.rate, duration: .minutes(30),
                    insulinType: state.insulinType, automatic: false, startDate: basal.startTime)
            }
        } else {
            state.shortTempBasal = nil
        }
    }
}

import CryptoKit
import Foundation
import LoopKit

public enum MedtrumUserBasalRecoveryError: LocalizedError {
    case changed, unavailable
    public var errorDescription: String? {
        String(localized: "Pump state changed or could not be confirmed. Protection remains active. Refresh and try again.",
            bundle: Bundle(for: MedtrumPumpManager.self))
    }
}

extension MedtrumPumpManager {
    public var basalRecoveryNeedsAttention: Bool { deliveryLock.withLock { state.basalDeliveryUncertain } }
    public var hasUserAcknowledgedBasalHistory: Bool {
        deliveryLock.withLock { state.userBasalRecoveryAudit.contains { $0["action"] as? String == "user_resumed_current_loop" } }
    }
    public var basalRecoveryPendingSummary: String? {
        deliveryLock.withLock {
            guard let request = state.pendingTempBasal else { return nil }
            let date = request.startDate.formatted(date: .abbreviated, time: .standard)
            return String(format: String(localized: "Original request: %@, %.2f U/h, %.0f min", bundle: Bundle(for: Self.self)),
                date, request.value, request.estimatedEndDate.timeIntervalSince(request.startDate) / 60)
        }
    }

    private var userRecoveryEligible: Bool {
        state.basalDeliveryUncertain && state.pendingTempBasal?.automatic == true &&
            !state.awaitingBasalReply && !state.awaitingBolusReply && !state.bolusDeliveryUncertain &&
            state.bolusDose == nil && state.shortTempBasal == nil && state.unresolvedShortTempBasals.isEmpty &&
            !state.patchSessionEnded && state.patchActivatedAt != nil && !state.patchId.isEmpty && !submittingDelivery
    }

    public var basalRecoveryDecisionToken: String? {
        deliveryLock.withLock {
            guard userRecoveryEligible, let request = state.pendingTempBasal else { return nil }
            let value = "\(state.pumpSN.hexEncodedString()):\(state.patchId.hexEncodedString()):\(state.patchActivatedAt!):\(request.decisionId?.uuidString ?? "none"):\(request.startDate.timeIntervalSinceReferenceDate):\(request.estimatedEndDate.timeIntervalSinceReferenceDate):\(request.value)"
            return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Explicit user choice, never called by automatic reconciliation. Captured UI token must still match.
    public func userResumeUnverifiedBasal(expectedToken: String, completion: @escaping (Error?) -> Void) {
        let query: MedtrumBasalSyncContext? = deliveryLock.withLock {
            guard userRecoveryEligible, !basalRecoveryInProgress, basalRecoveryDecisionToken == expectedToken else { return nil }
            deliveryGeneration = UUID()
            let query = captureBasalSyncContext()
            basalRecoveryInProgress = true
            userBasalRecoveryOwner = query.generation
            var audit: [String: Any] = ["id": query.generation.uuidString, "date": Date(),
                "action": "user_requested_resume", "historyVerified": false, "patchID": state.patchId,
                "activation": state.patchActivatedAt!]
            audit["pending"] = state.pendingTempBasal?.rawValue
            audit["checkpoint"] = state.basalRecoveryCheckpoint.flatMap { try? JSONEncoder().encode($0) }
            state.userBasalRecoveryAudit.append(audit)
            return query
        }
        guard let query else { completion(MedtrumUserBasalRecoveryError.changed); return }
        do { try checkpointDelivery() }
        catch { finishUserRecovery(query: query, error: error, completion: completion); return }
        ensureConnectedAndActive { error in
            if let error { self.finishUserRecovery(query: query, error: error, completion: completion); return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var (status, observedAt) = try self.userRecoveryRead(query: query)
                    if status.basal?.type.isTempBasal() == true {
                        // The confirmation explicitly permits ending the currently running temp first.
                        _ = self.bluetooth.write(CancelTempBasalPacket(), validation: {
                            self.deliveryLock.withLock { query.matches(self) && self.userRecoveryEligible &&
                                self.userBasalRecoveryOwner == query.generation }
                        })
                        // A lost cancellation reply is not retried; only a fresh STANDARD status can proceed.
                        (status, observedAt) = try self.userRecoveryRead(query: query)
                    }
                    try self.commitUserBasalRecovery(query: query, status: status, observedAt: observedAt)
                    self.finishUserRecovery(query: query, error: nil, completion: completion)
                } catch { self.finishUserRecovery(query: query, error: error, completion: completion) }
            }
        }
    }

    private func userRecoveryRead(query: MedtrumBasalSyncContext) throws -> (SynchronizePacketResponse, Date) {
        guard deliveryLock.withLock({ query.matches(self) && userRecoveryEligible && userBasalRecoveryOwner == query.generation }),
              let bluetooth else { throw MedtrumUserBasalRecoveryError.changed }
        let started = Date()
        guard case let .success(data) = bluetooth.write(SynchronizePacket()), let response = data as? SynchronizePacketResponse,
              deliveryLock.withLock({ query.matches(self) && StateSyncer.basalRecoverySessionIsCurrent(response, state: state) })
        else { throw MedtrumUserBasalRecoveryError.unavailable }
        return (response, started)
    }

    /// Same host-queue -> driver-lock transaction as verified recovery, but an explicitly different audit outcome.
    func commitUserBasalRecovery(query: MedtrumBasalSyncContext, status: SynchronizePacketResponse, observedAt: Date) throws {
        guard let persistBasalRecovery else { throw CocoaError(.fileWriteUnknown) }
        try persistBasalRecovery { save in
            try self.deliveryLock.withLock {
                let age = Date().timeIntervalSince(observedAt)
                guard query.matches(self), self.userRecoveryEligible, query.canRecover,
                      self.userBasalRecoveryOwner == query.generation,
                      StateSyncer.basalRecoverySessionIsCurrent(status, state: self.state),
                      let basal = status.basal, basal.type == .STANDARD, age >= 0,
                      age <= Self.loopSyncFreshnessInterval, let activation = self.state.patchActivatedAt else {
                    throw MedtrumUserBasalRecoveryError.changed
                }
                let dose = UnfinalizedDose(basalRate: basal.rate, insulinType: self.state.insulinType, startDate: observedAt)
                var audit = self.state.userBasalRecoveryAudit
                var entry: [String: Any] = ["id": query.generation.uuidString, "date": Date(),
                    "action": "user_resumed_current_loop", "historyVerified": false,
                    "patchID": self.state.patchId, "activation": activation, "observedAt": observedAt]
                entry["pending"] = self.state.pendingTempBasal?.rawValue
                entry["currentNativeBasal"] = try JSONEncoder().encode(basal)
                audit.append(entry)
                var candidate = self.state.rawValue
                candidate["userBasalRecoveryAudit"] = audit
                candidate.removeValue(forKey: "pendingTempBasal")
                candidate.removeValue(forKey: "basalRecoveryCheckpoint")
                candidate["basalDeliveryUncertain"] = false
                candidate["awaitingBasalReply"] = false
                candidate["legacyBasalRecoveryAllowed"] = false
                candidate["basalDose"] = dose.rawValue
                candidate["basalState"] = BasalState.active.rawValue
                candidate["pumpState"] = status.state.rawValue
                candidate["lastSync"] = observedAt
                try save(candidate)
                self.state.userBasalRecoveryAudit = audit
                self.state.pendingTempBasal = nil
                self.state.basalRecoveryCheckpoint = nil
                self.state.basalDeliveryUncertain = false
                self.state.awaitingBasalReply = false
                self.state.legacyBasalRecoveryAllowed = false
                self.state.basalDose = dose
                self.state.basalState = .active
                self.state.pumpState = status.state
                self.state.lastSync = observedAt
                self.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: basal, sessionID: self.state.patchId,
                    sessionStartedAt: activation, observedAt: observedAt)
                self.verifiedPumpObservation = MedtrumVerifiedPumpObservation(sessionID: self.state.patchId,
                    sessionStart: activation, date: observedAt)
                self.deliveryGeneration = UUID()
            }
        }
        historyRecoveryDiagnostic("user_override", index: 0)
    }

    private func finishUserRecovery(query: MedtrumBasalSyncContext, error: Error?, completion: @escaping (Error?) -> Void) {
        deliveryLock.withLock {
            if userBasalRecoveryOwner == query.generation {
                userBasalRecoveryOwner = nil
                basalRecoveryInProgress = false
                notifyStateDidChange()
            }
        }
        completion(error)
    }
}

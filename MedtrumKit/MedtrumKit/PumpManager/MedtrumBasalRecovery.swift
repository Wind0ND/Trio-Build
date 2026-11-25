import Foundation
import LoopKit

public struct MedtrumBasalRecoveryLogEntry: Sendable {
    public let timestamp: Date
    public let deviceIdentifier: String?
    public let message: String
    public init(timestamp: Date, deviceIdentifier: String?, message: String) {
        self.timestamp = timestamp; self.deviceIdentifier = deviceIdentifier; self.message = message
    }
}

struct MedtrumPendingBasalSignature: Equatable {
    let id: UUID?
    let start: Date
    let end: Date
    let rate: Double
    init(_ request: UnfinalizedDose) {
        id = request.decisionId; start = request.startDate; end = request.estimatedEndDate; rate = request.value
    }
}

struct MedtrumBasalSyncContext {
    let generation: UUID
    let sessionID: Data
    let sessionStart: Date?
    let pending: MedtrumPendingBasalSignature?
    let uncertain: Bool
    let canRecover: Bool
    let startedAt: Date

    func matches(_ manager: MedtrumPumpManager) -> Bool {
        generation == manager.deliveryGeneration && sessionID == manager.state.patchId &&
            sessionStart == manager.state.patchActivatedAt && !manager.state.patchSessionEnded &&
            pending == manager.state.pendingTempBasal.map(MedtrumPendingBasalSignature.init) &&
            uncertain == manager.state.basalDeliveryUncertain
    }
}

struct MedtrumVerifiedPumpObservation {
    let sessionID: Data
    let sessionStart: Date
    let date: Date
}

private final class BasalEvidenceCompletion {
    private let lock = NSLock()
    private var completion: (([MedtrumBasalRecoveryLogEntry]) -> Void)?
    init(_ completion: @escaping ([MedtrumBasalRecoveryLogEntry]) -> Void) { self.completion = completion }
    func finish(_ entries: [MedtrumBasalRecoveryLogEntry]) {
        let callback = lock.withLock { let callback = completion; completion = nil; return callback }
        callback?(entries)
    }
}

/// The actual native segment seen before a replacement command, not an estimated dose.
struct MedtrumBasalRecoveryBaseline: Codable {
    let segment: BasalData
    let sessionID: Data
    let sessionStartedAt: Date
    let observedAt: Date

    func matches(_ basal: BasalData) -> Bool {
        segment.type == .STANDARD && basal.type == .STANDARD &&
            segment.patchId == basal.patchId && segment.sequence == basal.sequence &&
            segment.startTime == basal.startTime && abs(segment.rate - basal.rate) < 0.000000001
    }
}

struct MedtrumBasalRecoveryCheckpoint: Codable {
    let baseline: MedtrumBasalRecoveryBaseline
    let requestID: UUID?
    let requestStart: Date
    let requestEnd: Date
    let requestRate: Double

    func matches(_ request: UnfinalizedDose) -> Bool {
        requestID == request.decisionId && requestStart == request.startDate &&
            requestEnd == request.estimatedEndDate && requestRate == request.value
    }
}

extension MedtrumPumpManager {
    func withLegacyBasalEvidence(for query: MedtrumBasalSyncContext,
                                completion: @escaping ([MedtrumBasalRecoveryLogEntry]) -> Void) {
        let window: DateInterval? = deliveryLock.withLock {
            guard query.matches(self), query.canRecover, state.legacyBasalRecoveryAllowed,
                  state.basalRecoveryCheckpoint == nil, let pending = query.pending else { return nil }
            return DateInterval(start: pending.start.addingTimeInterval(-600), end: pending.start)
        }
        guard let window, let provider = legacyBasalEvidenceProvider else { completion([]); return }
        let gate = BasalEvidenceCompletion(completion)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { gate.finish([]) }
        provider(window) { gate.finish($0) }
    }
    func ensureAutomaticBasalBaseline() -> Bool {
        func hasBaseline() -> Bool {
            deliveryLock.withLock {
                guard let baseline = verifiedBasalBaseline else { return false }
                let age = Date().timeIntervalSince(baseline.observedAt)
                return baseline.sessionID == state.patchId && baseline.sessionStartedAt == state.patchActivatedAt &&
                    baseline.segment.type == .STANDARD && age >= 0 &&
                    age <= Self.loopSyncFreshnessInterval && !status.deliveryIsUncertain
            }
        }
        if hasBaseline() { return true }
        guard let bluetooth else { return false }
        let query = captureBasalSyncContext()
        guard case let .success(data) = bluetooth.write(SynchronizePacket()),
              let response = data as? SynchronizePacketResponse,
              StateSyncer.basalRecoverySessionIsCurrent(response, state: state) else { return false }
        StateSyncer.sync(syncResponse: response, state: state, pumpManager: self, duringReconnect: false,
            fullSync: true, recoveryQuery: query)
        return hasBaseline()
    }

    func captureBasalSyncContext() -> MedtrumBasalSyncContext {
        deliveryLock.withLock {
            MedtrumBasalSyncContext(generation: deliveryGeneration, sessionID: state.patchId,
                sessionStart: state.patchActivatedAt,
                pending: state.pendingTempBasal.map(MedtrumPendingBasalSignature.init),
                uncertain: state.basalDeliveryUncertain,
                canRecover: state.basalDeliveryUncertain && !state.awaitingBasalReply &&
                    !submittingDelivery && !basalRecoveryInProgress, startedAt: Date())
        }
    }

    func invalidateBasalObservation() {
        deliveryLock.withLock {
            deliveryGeneration = UUID()
            verifiedBasalBaseline = nil
            verifiedPumpObservation = nil
        }
    }

    func verifiedPumpDataDate(at now: Date) -> Date? {
        deliveryLock.withLock {
            guard !status.deliveryIsUncertain, state.pumpState.isDelivering, !state.patchSessionEnded,
                  let observation = verifiedPumpObservation, observation.sessionID == state.patchId,
                  observation.sessionStart == state.patchActivatedAt else { return nil }
            let age = now.timeIntervalSince(observation.date)
            return age.isFinite && age >= 0 && age <= Self.loopSyncFreshnessInterval ? observation.date : nil
        }
    }

    func cachedPumpDataDate(at now: Date) -> Date? {
        deliveryLock.withLock {
            guard let activated = state.patchActivatedAt, !state.patchSessionEnded, state.pumpState.isDelivering,
                  !status.deliveryIsUncertain, now.timeIntervalSince(activated) >= .minutes(4) else { return nil }
            return verifiedPumpDataDate(at: now)
        }
    }

    func captureBasalRecoveryCheckpoint(for request: UnfinalizedDose?) -> MedtrumBasalRecoveryCheckpoint? {
        guard let request, request.automatic, state.shortTempBasal == nil,
              let baseline = verifiedBasalBaseline,
              baseline.sessionID == state.patchId, baseline.sessionStartedAt == state.patchActivatedAt,
              baseline.segment.type == .STANDARD,
              baseline.observedAt <= request.startDate,
              request.startDate.timeIntervalSince(baseline.observedAt) <= Self.loopSyncFreshnessInterval else { return nil }
        return MedtrumBasalRecoveryCheckpoint(baseline: baseline, requestID: request.decisionId,
            requestStart: request.startDate, requestEnd: request.estimatedEndDate, requestRate: request.value)
    }

    /// The host owns the serial storage queue, then this transaction locks the driver.
    /// Normal raw snapshots stay conservative until the candidate is durably saved.
    func completeBasalRecovery(query: MedtrumBasalSyncContext, events: [NewPumpEvent], reason: String,
                              confirmedDose: UnfinalizedDose? = nil) {
        var saved = true
        do {
            guard let persistBasalRecovery else { throw CocoaError(.fileWriteUnknown) }
            try persistBasalRecovery { save in
                try self.deliveryLock.withLock {
                    guard query.matches(self), query.canRecover, !self.state.awaitingBasalReply else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    var candidate = self.state.rawValue
                    candidate.removeValue(forKey: "pendingTempBasal")
                    candidate.removeValue(forKey: "basalRecoveryCheckpoint")
                    candidate["basalDeliveryUncertain"] = false
                    candidate["awaitingBasalReply"] = false
                    candidate["legacyBasalRecoveryAllowed"] = false
                    if let confirmedDose { candidate["basalDose"] = confirmedDose.rawValue }
                    try save(candidate)
                    if let confirmedDose { self.state.basalDose = confirmedDose }
                    self.state.pendingTempBasal = nil
                    self.state.basalRecoveryCheckpoint = nil
                    self.state.basalDeliveryUncertain = false
                    self.state.legacyBasalRecoveryAllowed = false
                    self.deliveryGeneration = UUID()
                }
            }
        }
        catch { saved = false }
        deliveryLock.withLock {
            basalRecoveryInProgress = false
            if saved {
                MedtrumLogger(category: "BasalRecovery").info("Pending automatic basal resolved: \(reason); old command will not be replayed")
                emitPumpEvents(events)
            } else {
                MedtrumLogger(category: "BasalRecovery").warning("Basal recovery not committed; keeping delivery protected")
            }
            NotificationCenter.default.post(name: Notification.Name("com.trio.diagnostics.event"), object: nil,
                userInfo: ["schema": 1, "feature": "medtrum", "stage": "basal_recovery",
                           "outcome": saved ? "recovered" : "checkpoint_failed"])
            notifyStateDidChange()
        }
    }
}

extension StateSyncer {
    static func basalRecoverySessionIsCurrent(_ response: SynchronizePacketResponse, state: MedtrumPumpState,
                                             requiresDelivery: Bool = true) -> Bool {
        guard !response.invalidPayload, !response.truncated,
              response.state.isDelivering || (!requiresDelivery && response.state.isDeliveryHalted),
              !state.patchSessionEnded, !state.patchActivationIsProvisional, state.patchId.toUInt64() > 0,
              let sessionStart = state.patchActivatedAt, let reportedStart = response.startTime,
              sessionStart == reportedStart, let basal = response.basal,
              basal.patchId == Double(state.patchId.toUInt64()),
              let storage = response.storage, storage.patchId == basal.patchId,
              basal.rate.isFinite, (0 ... 30).contains(basal.rate),
              basal.type != .NONE, basal.sequence.isFinite, basal.sequence >= 0,
              basal.startTime >= sessionStart else { return false }
        return true
    }

    static func unstartedAutomaticBasalReason(state: MedtrumPumpState, response: SynchronizePacketResponse,
                                              now: Date, evidence: [MedtrumBasalRecoveryLogEntry], deviceIdentifier: String) -> String? {
        guard state.basalDeliveryUncertain, !state.awaitingBasalReply, state.shortTempBasal == nil,
              let request = state.pendingTempBasal,
              request.automatic, request.type == .tempBasal, request.startDate <= now,
              request.value.isFinite, request.estimatedEndDate > request.startDate,
              basalRecoverySessionIsCurrent(response, state: state), let basal = response.basal,
              basal.type == .STANDARD else { return nil }

        if let checkpoint = state.basalRecoveryCheckpoint {
            guard checkpoint.matches(request), checkpoint.baseline.sessionID == state.patchId,
                  checkpoint.baseline.sessionStartedAt == state.patchActivatedAt,
                  checkpoint.baseline.observedAt <= request.startDate,
                  request.startDate.timeIntervalSince(checkpoint.baseline.observedAt) <= MedtrumPumpManager.loopSyncFreshnessInterval,
                  checkpoint.baseline.matches(basal) else { return nil }
            return "unchanged_native_segment"
        }

        // A pre-request native predecessor, not a host timestamp approximation, is required.
        guard state.legacyBasalRecoveryAllowed, request.estimatedEndDate <= now,
              request.estimatedEndDate.timeIntervalSince(request.startDate) == 1800,
              let prior = legacyBasalPredecessor(evidence, state: state, request: request,
                deviceIdentifier: deviceIdentifier), prior.type == .ABSOLUTE_TEMP,
              prior.rate != request.value, prior.sequence >= 1, prior.sequence < 65535,
              prior.sequence.rounded() == prior.sequence, basal.sequence == prior.sequence + 1,
              basal.startTime > prior.startTime else { return nil }
        return "legacy_verified_adjacent_native_segment"
    }

    static func legacyBasalPredecessor(_ entries: [MedtrumBasalRecoveryLogEntry], state: MedtrumPumpState,
                                      request: UnfinalizedDose, deviceIdentifier: String) -> BasalData? {
        guard !deviceIdentifier.isEmpty else { return nil }
        var packets: [(Date, SynchronizePacketResponse)] = []
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard entry.deviceIdentifier == deviceIdentifier, entry.timestamp < request.startDate,
                  request.startDate.timeIntervalSince(entry.timestamp) <= 600 else { continue }
            let marker: String
            if entry.message.hasPrefix("[INFO] PeripheralManager.swift - parseStateUpdate(") { marker = "State update: " }
            else if entry.message.hasPrefix("[INFO] MedtrumPumpManager.swift - syncPumpData(") { marker = "Manual sync: " }
            else { continue }
            guard let range = entry.message.range(of: marker),
                  let data = String(entry.message[range.upperBound...]).data(using: .utf8),
                  let response = try? JSONDecoder().decode(SynchronizePacketResponse.self, from: data),
                  !response.invalidPayload, !response.truncated, response.state.isDelivering else { return nil }
            let expected = Double(state.patchId.toUInt64())
            if let start = response.startTime, start != state.patchActivatedAt { return nil }
            if let storage = response.storage, storage.patchId != expected { return nil }
            if let basal = response.basal {
                guard basal.patchId == expected else { return nil }
                if let previous = packets.last?.1.basal,
                   (basal.sequence != previous.sequence || basal.type != previous.type ||
                    basal.startTime != previous.startTime || basal.rate != previous.rate) {
                    // A newer segment cannot be attributed using an older full packet's identity.
                    packets.removeAll()
                }
            }
            if response.startTime == state.patchActivatedAt, response.storage?.patchId == expected,
               response.basal?.patchId == expected { packets.append((entry.timestamp, response)) }
        }
        return packets.max(by: { $0.0 < $1.0 })?.1.basal
    }
}

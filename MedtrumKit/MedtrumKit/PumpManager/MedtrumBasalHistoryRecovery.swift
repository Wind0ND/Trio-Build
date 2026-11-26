import CryptoKit
import Foundation
import LoopKit

struct MedtrumFrozenClockMapping: Codable {
    let sessionID: Data
    let activation: Date
    let sampledAt: Date
    let offset: TimeInterval
}

struct MedtrumBasalHistoryResolution {
    let pending: MedtrumPendingBasalSignature
    let current: BasalData
    let activation: Date
    let serial: UInt64
    let executed: MedtrumBasalHistoryRecord?
    let clockOffset: TimeInterval?

    static func sameSegment(_ a: BasalData, _ b: BasalData) -> Bool {
        a.type == b.type && a.patchId == b.patchId && a.sequence == b.sequence &&
            a.startTime == b.startTime && abs(a.rate - b.rate) < 0.000001
    }

    static func reconcile(request: UnfinalizedDose, anchor: BasalData,
                          records: [MedtrumBasalHistoryRecord], current: BasalData,
                          serial: UInt64, patchID: Int, activation: Date,
                          clockOffset: TimeInterval?) -> MedtrumBasalHistoryResolution? {
        guard request.automatic, request.type == .tempBasal, request.value.isFinite,
              request.startDate <= Date(), request.estimatedEndDate > request.startDate,
              current.type == .STANDARD, current.patchId == Double(patchID),
              current.startTime <= Date().addingTimeInterval(120),
              anchor.patchId == Double(patchID), anchor.sequence.rounded() == anchor.sequence,
              current.sequence.rounded() == current.sequence,
              anchor.sequence >= 1, current.sequence <= 65535, current.sequence > anchor.sequence,
              records.count == Int(current.sequence - anchor.sequence),
              let first = records.first, first.sequence == Int(anchor.sequence),
              first.type == anchor.type, first.start == anchor.startTime,
              abs(first.rate - anchor.rate) < 0.000001 else { return nil }
        var next = Int(anchor.sequence)
        var end = anchor.startTime
        for r in records {
            guard r.sequence == next, r.serial == serial, r.patchID == patchID,
                  r.start == end, r.start >= activation, r.end >= r.start,
                  r.rate.isFinite, (0...30).contains(r.rate), r.delivered.isFinite, r.delivered >= 0,
                  r.delivered <= r.rate * r.end.timeIntervalSince(r.start) / 3600 + 0.050001,
                  r.type == .STANDARD || r.type == .ABSOLUTE_TEMP else { return nil }
            next += 1; end = r.end
        }
        guard end == current.startTime else { return nil }
        let later = Array(records.dropFirst())
        let temps = later.filter { $0.type != .STANDARD }
        var actual: MedtrumBasalHistoryRecord?
        if !temps.isEmpty {
            guard temps.count == 1, let temp = temps.first,
                  abs(temp.rate - request.value) < 0.000001,
                  let offset = clockOffset, offset.isFinite, abs(offset) <= 120,
                  temp.end > temp.start,
                  temp.end.timeIntervalSince(temp.start) <= request.estimatedEndDate.timeIntervalSince(request.startDate) + 1,
                  temp.start.addingTimeInterval(-offset) >= request.startDate.addingTimeInterval(-1),
                  temp.start.addingTimeInterval(-offset) <= request.startDate.addingTimeInterval(60) else { return nil }
            actual = temp
        }
        return MedtrumBasalHistoryResolution(pending: MedtrumPendingBasalSignature(request), current: current,
            activation: activation, serial: serial, executed: actual, clockOffset: clockOffset)
    }

    func event(for request: UnfinalizedDose) -> NewPumpEvent? {
        guard let r = executed, let offset = clockOffset else { return nil }
        let dose = UnfinalizedDose(decisionId: request.decisionId, tempRate: r.rate,
            duration: r.end.timeIntervalSince(r.start), insulinType: request.insulinType,
            automatic: true, startDate: r.start.addingTimeInterval(-offset))
        var entry = dose.toDoseEntry(isMutable: false, endDate: r.end.addingTimeInterval(-offset))
        entry.deliveredUnits = r.delivered
        // Native identity is stable even if a later clock read maps wall time slightly differently.
        let identity = "\(serial):\(r.patchID):\(activation.timeIntervalSinceReferenceDate):\(r.sequence):\(r.start.timeIntervalSinceReferenceDate)"
        let raw = Data(SHA256.hash(data: Data(identity.utf8)))
        return NewPumpEvent(date: entry.startDate, dose: entry, raw: raw, title: "Reconciled Temp Basal")
    }
}

private struct MedtrumHistoryCacheKey: Equatable {
    let request: MedtrumPendingBasalSignature
    let patch: Data
    let activation: Date
    let serial: UInt64
    let anchorSequence: Double
    let anchorStart: Date
    let anchorRate: Double
}

struct MedtrumBasalHistoryCache {
    fileprivate var key: MedtrumHistoryCacheKey?
    var records: [Int: MedtrumBasalHistoryRecord] = [:]
}

extension MedtrumPumpManager {
    /// Only reads native history. The caller subsequently applies one attributable full status.
    func withBasalHistory(for query: MedtrumBasalSyncContext, response: SynchronizePacketResponse,
                          evidence: [MedtrumBasalRecoveryLogEntry],
                          completion: @escaping (SynchronizePacketResponse, MedtrumBasalHistoryResolution?) -> Void) {
        let anchor: BasalData? = deliveryLock.withLock {
            guard query.matches(self), query.canRecover, !basalHistoryReadInFlight,
                  state.shortTempBasal == nil || (state.shortTempBasal?.automaticPulse == true && state.shortTempBasal?.commandID == state.pendingTempBasal?.decisionId),
                  let request = state.pendingTempBasal, request.automatic,
                  StateSyncer.basalRecoverySessionIsCurrent(response, state: state),
                  response.basal?.type == .STANDARD,
                  StateSyncer.unstartedAutomaticBasalReason(state: state, response: response, now: Date(),
                    evidence: evidence, deviceIdentifier: logDeviceIdentifier) == nil else { return nil }
            if let c = state.basalRecoveryCheckpoint {
                guard c.matches(request), c.baseline.sessionID == state.patchId,
                      c.baseline.sessionStartedAt == state.patchActivatedAt else { return nil }
                return c.baseline.segment
            }
            guard state.legacyBasalRecoveryAllowed else { return nil }
            return StateSyncer.legacyBasalPredecessor(evidence, state: state, request: request,
                deviceIdentifier: logDeviceIdentifier)
        }
        guard let anchor else { completion(response, nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.collectBasalHistory(query: query, initial: response, anchor: anchor, completion: completion)
        }
    }

    private func collectBasalHistory(query: MedtrumBasalSyncContext, initial: SynchronizePacketResponse,
                                     anchor: BasalData,
                                     completion: (SynchronizePacketResponse, MedtrumBasalHistoryResolution?) -> Void) {
        var latest = initial
        var resolution: MedtrumBasalHistoryResolution?
        var ownsRead = false
        defer {
            if ownsRead { deliveryLock.withLock { basalHistoryReadInFlight = false } }
            completion(latest, resolution)
        }
        let captured: (MedtrumHistoryCacheKey, UnfinalizedDose)? = deliveryLock.withLock {
            guard query.matches(self), query.canRecover, !basalHistoryReadInFlight,
                  let request = state.pendingTempBasal, let activation = state.patchActivatedAt,
                  let tip = initial.basal, anchor.sequence >= 1, anchor.sequence.rounded() == anchor.sequence,
                  tip.sequence > anchor.sequence, tip.sequence <= 65535, tip.sequence.rounded() == tip.sequence,
                  state.patchId.toUInt64() <= 65535, state.pumpSN.count == 4 else { return nil }
            let key = MedtrumHistoryCacheKey(request: MedtrumPendingBasalSignature(request), patch: state.patchId,
                activation: activation, serial: Data(state.pumpSN.reversed()).toUInt64(),
                anchorSequence: anchor.sequence, anchorStart: anchor.startTime, anchorRate: anchor.rate)
            if basalHistoryCache.key != key { basalHistoryCache = MedtrumBasalHistoryCache(key: key) }
            basalHistoryReadInFlight = true
            return (key, request)
        }
        guard let (key, request) = captured, let tip = initial.basal else { return }
        ownsRead = true
        let began = Date()
        var reads = 0
        for index in Int(anchor.sequence)..<Int(tip.sequence) {
            guard deliveryLock.withLock({ query.matches(self) && basalHistoryCache.key == key }) else { return }
            if deliveryLock.withLock({ basalHistoryCache.records[index] != nil }) { continue }
            guard reads < 12, Date().timeIntervalSince(began) < 20 else {
                historyRecoveryDiagnostic("history_progress", index: index); return
            }
            reads += 1
            let packet = GetBasalRecordPacket(index: index, patchID: Int(key.patch.toUInt64()))
            guard let bluetooth, case let .success(data) = bluetooth.write(packet),
                  let record = data as? MedtrumBasalHistoryRecord,
                  record.serial == key.serial, record.patchID == Int(key.patch.toUInt64()), record.sequence == index else {
                historyRecoveryDiagnostic("history_failed", index: index); return
            }
            let stored = deliveryLock.withLock {
                guard query.matches(self), basalHistoryCache.key == key else { return false }
                basalHistoryCache.records[index] = record
                return true
            }
            guard stored else { return }
        }
        // A second full status prevents completion against a tip that changed during the history read.
        guard let bluetooth, deliveryLock.withLock({ query.matches(self) }),
              case let .success(data) = bluetooth.write(SynchronizePacket()),
              let status = data as? SynchronizePacketResponse,
              deliveryLock.withLock({ query.matches(self) && StateSyncer.basalRecoverySessionIsCurrent(status, state: state) }),
              let current = status.basal else { return }
        latest = status
        let records = deliveryLock.withLock { (Int(anchor.sequence)..<Int(tip.sequence)).compactMap { basalHistoryCache.records[$0] } }
        let offset: TimeInterval? = deliveryLock.withLock {
            guard let checkpoint = state.basalRecoveryCheckpoint, checkpoint.matches(request),
                  let mapping = checkpoint.clockMapping, mapping.sessionID == key.patch,
                  mapping.activation == key.activation, mapping.sampledAt <= request.startDate,
                  request.startDate.timeIntervalSince(mapping.sampledAt) <= Self.loopSyncFreshnessInterval else { return nil }
            return mapping.offset
        }
        resolution = deliveryLock.withLock {
            guard query.matches(self) else { return nil }
            return MedtrumBasalHistoryResolution.reconcile(request: request, anchor: anchor, records: records,
                current: current, serial: key.serial, patchID: Int(key.patch.toUInt64()),
                activation: key.activation, clockOffset: offset)
        }
        historyRecoveryDiagnostic(resolution == nil ? "history_inconclusive" : "history_verified", index: Int(current.sequence))
    }

    func historyRecoveryDiagnostic(_ outcome: String, index: Int) {
        MedtrumLogger(category: "BasalHistory").info("Basal history \(outcome), record index \(index)")
        NotificationCenter.default.post(name: Notification.Name("com.trio.diagnostics.event"), object: nil,
            userInfo: ["schema": 1, "feature": "medtrum", "stage": "basal_recovery", "outcome": outcome, "count": index])
    }

    func completeBasalHistoryRecovery(query: MedtrumBasalSyncContext, events: [NewPumpEvent],
                                       reason: String, scheduledDose: UnfinalizedDose?) {
        guard !events.isEmpty else {
            completeBasalRecovery(query: query, events: [], reason: reason, confirmedDose: scheduledDose); return
        }
        emitPumpEvents(events, replacePendingEvents: false) { error in
            guard error == nil else {
                self.deliveryLock.withLock { self.basalRecoveryInProgress = false; self.notifyStateDidChange() }
                self.historyRecoveryDiagnostic("history_store_failed", index: 0)
                return
            }
            let actual = events.first(where: { $0.type == .tempBasal })?.dose
            self.completeBasalRecovery(query: query, events: [], reason: reason, confirmedDose: scheduledDose,
                resolvedPulseStart: actual?.startDate, resolvedPulseEnd: actual?.endDate)
        }
    }
}

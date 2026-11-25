import Foundation
import LoopKit

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
    func ensureAutomaticBasalBaseline() -> Bool {
        func hasBaseline() -> Bool {
            deliveryLock.withLock {
                guard let baseline = verifiedBasalBaseline else { return false }
                let age = Date().timeIntervalSince(baseline.observedAt)
                return baseline.sessionID == state.patchId && baseline.sessionStartedAt == state.patchActivatedAt &&
                    baseline.segment.type == .STANDARD && state.basalDose.type == .basal &&
                    abs(baseline.segment.rate - state.basalDose.value) < 0.000000001 && age >= 0 &&
                    age <= Self.loopSyncFreshnessInterval && !status.deliveryIsUncertain
            }
        }
        if hasBaseline() { return true }
        guard let bluetooth, case let .success(data) = bluetooth.write(SynchronizePacket()),
              let response = data as? SynchronizePacketResponse,
              StateSyncer.basalRecoverySessionIsCurrent(response, state: state) else { return false }
        StateSyncer.sync(syncResponse: response, state: state, pumpManager: self, duringReconnect: false, fullSync: true)
        return hasBaseline()
    }

    func cachedPumpDataDate(at now: Date) -> Date? {
        deliveryLock.withLock {
            guard let activated = state.patchActivatedAt, !state.patchSessionEnded, state.pumpState.isDelivering,
                  !status.deliveryIsUncertain, now.timeIntervalSince(activated) >= .minutes(4) else { return nil }
            let age = now.timeIntervalSince(state.lastSync)
            guard age.isFinite, age >= 0, age <= Self.loopSyncFreshnessInterval else { return nil }
            return state.lastSync
        }
    }

    func captureBasalRecoveryCheckpoint(for request: UnfinalizedDose?) -> MedtrumBasalRecoveryCheckpoint? {
        guard let request, request.automatic, state.shortTempBasal == nil,
              state.basalDose.type == .basal, let baseline = verifiedBasalBaseline,
              baseline.sessionID == state.patchId, baseline.sessionStartedAt == state.patchActivatedAt,
              baseline.segment.type == .STANDARD, abs(baseline.segment.rate - state.basalDose.value) < 0.000000001,
              baseline.observedAt <= request.startDate,
              request.startDate.timeIntervalSince(baseline.observedAt) <= Self.loopSyncFreshnessInterval else { return nil }
        return MedtrumBasalRecoveryCheckpoint(baseline: baseline, requestID: request.decisionId,
            requestStart: request.startDate, requestEnd: request.estimatedEndDate, requestRate: request.value)
    }

    /// Used outside deliveryLock. The transient gate keeps all new commands blocked until the save completes.
    func completeBasalRecovery(request: UnfinalizedDose, checkpoint: MedtrumBasalRecoveryCheckpoint?,
                               sessionID: Data, sessionStart: Date?, events: [NewPumpEvent], reason: String) {
        var saved = true
        do { try checkpointDelivery() }
        catch { saved = false }
        deliveryLock.withLock {
            let sameSession = state.patchId == sessionID && state.patchActivatedAt == sessionStart
            if !saved, sameSession, state.pendingTempBasal == nil {
                state.pendingTempBasal = request
                state.basalRecoveryCheckpoint = checkpoint
                state.basalDeliveryUncertain = true
            }
            basalRecoveryInProgress = false
            if saved, sameSession {
                MedtrumLogger(category: "BasalRecovery").info("Pending automatic basal resolved: \(reason); old command will not be replayed")
                emitPumpEvents(events)
            } else {
                MedtrumLogger(category: "BasalRecovery").warning("Basal recovery not committed; keeping delivery protected")
            }
            NotificationCenter.default.post(name: Notification.Name("com.trio.diagnostics.event"), object: nil,
                userInfo: ["schema": 1, "feature": "medtrum", "stage": "basal_recovery",
                           "outcome": saved && sameSession ? "recovered" : "checkpoint_failed"])
            notifyStateDidChange()
        }
    }
}

extension StateSyncer {
    static func basalRecoverySessionIsCurrent(_ response: SynchronizePacketResponse, state: MedtrumPumpState) -> Bool {
        guard !response.invalidPayload, !response.truncated, response.state == .active,
              state.pumpState.isDelivering, !state.patchSessionEnded, state.patchId.toUInt64() > 0,
              let sessionStart = state.patchActivatedAt, let reportedStart = response.startTime,
              sessionStart == reportedStart, let basal = response.basal,
              basal.patchId == Double(state.patchId.toUInt64()),
              let storage = response.storage, storage.patchId == basal.patchId,
              basal.rate.isFinite, (0 ... 30).contains(basal.rate),
              basal.sequence.isFinite, basal.sequence >= 0, basal.startTime >= sessionStart else { return false }
        return true
    }

    static func unstartedAutomaticBasalReason(state: MedtrumPumpState, response: SynchronizePacketResponse,
                                              now: Date) -> String? {
        guard state.basalDeliveryUncertain, !state.awaitingBasalReply, state.shortTempBasal == nil,
              state.basalDose.type == .basal, let request = state.pendingTempBasal,
              request.automatic, request.type == .tempBasal, request.startDate <= now,
              request.value.isFinite, request.estimatedEndDate > request.startDate,
              basalRecoverySessionIsCurrent(response, state: state), let basal = response.basal,
              basal.type == .STANDARD, abs(basal.rate - state.basalDose.value) < 0.000000001 else { return nil }

        if let checkpoint = state.basalRecoveryCheckpoint {
            guard checkpoint.matches(request), checkpoint.baseline.sessionID == state.patchId,
                  checkpoint.baseline.sessionStartedAt == state.patchActivatedAt,
                  checkpoint.baseline.observedAt <= request.startDate,
                  request.startDate.timeIntervalSince(checkpoint.baseline.observedAt) <= MedtrumPumpManager.loopSyncFreshnessInterval,
                  checkpoint.baseline.matches(basal) else { return nil }
            return "unchanged_native_segment"
        }

        // Narrow migration for build35's ordinary 30-minute automatic replacement.
        // The retained scheduled dose is the pre-write cancellation receipt. A later scheduled
        // transition cannot prove the failed command never ran and must remain protected.
        let clockAge = now.timeIntervalSince(state.pumpTimeSyncedAt)
        let baseline = state.basalDose
        let gap = request.startDate.timeIntervalSince(baseline.startDate)
        let localStart = state.localDate(forPumpDate: basal.startTime)
        guard request.estimatedEndDate <= now,
              request.estimatedEndDate.timeIntervalSince(request.startDate) == 1800,
              clockAge.isFinite, clockAge >= 0, clockAge <= MedtrumPumpManager.patchTimeRefreshInterval,
              gap >= 0, gap <= 2, baseline.startDate <= now,
              abs(localStart.timeIntervalSince(baseline.startDate)) <= 2,
              localStart <= request.startDate.addingTimeInterval(2) else { return nil }
        return "legacy_unchanged_scheduled_segment"
    }
}

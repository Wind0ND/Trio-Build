import Foundation
@preconcurrency import LoopKit

/// In-process presentation receipt, separate from exported diagnostics and the sample's measurement time.
public enum OttaiGridRecoveryReceipt {
    public static let notification = Notification.Name("com.trio.ottai.gridRecovery.submitted")
    public static let measuredAtKey = "measuredAt"
    public static let receivedAtKey = "receivedAt"
}

enum OttaiReconnectGridRecovery {
    static let interval: TimeInterval = TimeInterval(OttaiCGMManager.forwardGridStep) * 60

    static func target(
        latestLiveSequence: UInt16,
        lastGridSequence: UInt16,
        firstUsableSequence: UInt16,
        lastSubmittedAt: Date?,
        now: Date
    ) -> UInt16? {
        let step = OttaiCGMManager.forwardGridStep
        let remainder = latestLiveSequence % step
        guard let lastSubmittedAt, now.timeIntervalSince(lastSubmittedAt) > interval, remainder != 0 else { return nil }
        let target = latestLiveSequence - remainder
        // The receive watermark can advance before a sample is handed to Trio.
        // Recheck that exact grid slot, then deduplicate using its actual sample date.
        guard target >= lastGridSequence, target >= firstUsableSequence, target > 0 else { return nil }
        return target
    }

    static func isFresh(sampleDate: Date, newerThan previous: Date?, now: Date) -> Bool {
        sampleDate > (previous ?? .distantPast) && sampleDate <= now && now.timeIntervalSince(sampleDate) <= interval
    }
}

/// One attempt per target per minute; a new grid target can recover immediately.
struct OttaiGridRecoveryThrottle {
    private var previous: (target: UInt16, date: Date)?

    mutating func reserve(target: UInt16, now: Date) -> Bool {
        if let previous, previous.target == target,
           now >= previous.date, now.timeIntervalSince(previous.date) < 60 { return false }
        previous = (target, now)
        return true
    }
}

extension OttaiCGMManager {
    @MainActor func startPriorityGridRequest(newest: UInt16, have: UInt16, firstUsableSequence: UInt16, monitor: OttaiSensorMonitor) -> Bool {
        guard priorityGridSequence == nil, let sequence = OttaiReconnectGridRecovery.target(
            latestLiveSequence: newest,
            lastGridSequence: have,
            firstUsableSequence: firstUsableSequence,
            lastSubmittedAt: state.lastGridSubmissionAt ?? state.latestForwardedToLoopAt,
            now: Date()
        ), gridRecoveryThrottle.reserve(target: sequence, now: Date()) else { return false }

        pendingBackfillFrom = have
        priorityGridSequence = sequence
        OttaiDiagnosticEvent.record(.reconnectGrid, .started)
        priorityGridTask = Task { [weak self, weak monitor] in
            guard let monitor else { return }
            do {
                try await monitor.requestHistoricalBackfill(fromSequence: sequence, count: 1)
                try await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, self.monitor === monitor, self.priorityGridSequence == sequence else { return }
                self.finishPriorityGridRequest(.timedOut)
            } catch {
                guard !Task.isCancelled, let self, self.monitor === monitor, self.priorityGridSequence == sequence else { return }
                self.finishPriorityGridRequest(.failed)
            }
        }
        return true
    }

    @MainActor func submitPriorityGridIfReady(_ sample: GlucoseSample, newSample: NewGlucoseSample) -> Bool {
        guard sample.source == .historicalBackfill, sample.sequence == priorityGridSequence else { return false }
        guard sample.elapsedSeconds != nil, state.activatedAt != nil,
              OttaiReconnectGridRecovery.isFresh(sampleDate: sample.date, newerThan: state.latestForwardedToLoopAt, now: Date()),
              submitGridSamples([newSample])
        else {
            finishPriorityGridRequest(.failed)
            return false
        }
        lastPriorityGrid = (sample.sequence, sample.date)
        Foundation.NotificationCenter.default.post(
            name: OttaiGridRecoveryReceipt.notification, object: nil,
            userInfo: [OttaiGridRecoveryReceipt.measuredAtKey: sample.date, OttaiGridRecoveryReceipt.receivedAtKey: Date()]
        )
        finishPriorityGridRequest(.present)
        return true
    }

    @MainActor func finishPriorityGridRequest(_ outcome: OttaiDiagnosticEvent.Outcome) {
        guard priorityGridSequence != nil else { return }
        priorityGridTask?.cancel()
        priorityGridTask = nil
        priorityGridSequence = nil
        OttaiDiagnosticEvent.record(.reconnectGrid, outcome)
    }
}

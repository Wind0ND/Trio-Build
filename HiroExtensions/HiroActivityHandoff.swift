import ActivityKit
import Foundation
import PrivacyKit

/// ActivityKit holds the next session while hiro is suspended. A scheduled snapshot
/// starts private and overdue until the app can publish an actual reading.
@available(iOS 16.2, *)
@MainActor final class HiroActivityHandoff {
    typealias Session = Activity<LiveActivityAttributes>
    private var scheduled: Session?
    private var observation: Task<Void, Never>?
    private var retryAfter = Date.distantPast

    deinit { observation?.cancel() }

    @available(iOS 26.0, *)
    private var pending: [Session] {
        var sessions = Session.activities.filter { $0.activityState == .pending }
        if let scheduled, scheduled.activityState == .pending,
           !sessions.contains(where: { $0.id == scheduled.id }) { sessions.append(scheduled) }
        return sessions
    }

    @available(iOS 26.0, *)
    func cancel() async {
        let sessions = pending
        observation?.cancel()
        observation = nil
        scheduled = nil
        for session in sessions { await session.end(nil, dismissalPolicy: .immediate) }
        retryAfter = .distantPast
    }

    @available(iOS 26.0, *)
    func prepare(after current: Session, foreground: Bool,
                 placeholder: () -> LiveActivityAttributes.ContentState,
                 onStart: @escaping @MainActor () async -> Void) async {
        guard PrivacyPreference.scheduledHandoffEnabled else { await cancel(); return }
        let now = Date()
        guard let start = ActivityLifecyclePolicy.successorDate(start: current.attributes.startDate, now: now) else { return }
        var match: Session?
        for session in pending {
            if abs(session.attributes.startDate.timeIntervalSince(start)) < 1, match == nil {
                match = session
            } else if foreground {
                await session.end(nil, dismissalPolicy: .immediate)
            }
        }
        if let match { observe(match, onStart: onStart); return }
        guard foreground, now >= retryAfter, Date() < start, PrivacyPreference.scheduledHandoffEnabled,
              current.activityState == .active || current.activityState == .stale else { return }
        do {
            let session = try Session.request(attributes: .init(startDate: start),
                content: ActivityContent(state: placeholder(), staleDate: start),
                pushType: nil, style: .standard,
                alertConfiguration: .init(title: "hiro", body: "", sound: .default), start: start)
            observe(session, onStart: onStart)
            DiagnosticEventStore.shared.record(feature: "activity", stage: "handoff", outcome: "scheduled")
        } catch {
            retryAfter = now.addingTimeInterval(60)
            warning(.liveActivity, "Could not schedule the next Live Activity", error: error)
            DiagnosticEventStore.shared.record(feature: "activity", stage: "handoff", outcome: "failed")
        }
    }

    private func observe(_ session: Session, onStart: @escaping @MainActor () async -> Void) {
        guard scheduled?.id != session.id else { return }
        scheduled = session
        observation?.cancel()
        observation = Task { [weak self] in
            for await state in session.activityStateUpdates {
                guard !Task.isCancelled, self?.scheduled?.id == session.id else { return }
                switch state {
                case .active, .stale:
                    self?.scheduled = nil
                    DiagnosticEventStore.shared.record(feature: "activity", stage: "handoff", outcome: "active")
                    await onStart()
                    return
                case .ended, .dismissed:
                    self?.scheduled = nil
                    return
                default: continue
                }
            }
        }
    }
}

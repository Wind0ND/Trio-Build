import ActivityKit
import Foundation
import PrivacyKit

/// ActivityKit holds the next session while hiro is suspended. A scheduled snapshot
/// starts private and overdue until the app can publish an actual reading.
@available(iOS 16.2, *)
@MainActor final class HiroActivityHandoff {
    typealias Session = Activity<LiveActivityAttributes>
    private var scheduled: Session?
    private var lastSubmitted: LiveActivityAttributes.ContentState?
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
        lastSubmitted = nil
        for session in sessions { await session.end(nil, dismissalPolicy: .immediate) }
        retryAfter = .distantPast
    }

    @available(iOS 26.0, *)
    func prepare(after current: Session, maySchedule: () -> Bool,
                 placeholder: () -> LiveActivityAttributes.ContentState,
                 onStart: @escaping @MainActor () async -> Void) async {
        guard PrivacyPreference.scheduledHandoffEnabled else { await cancel(); return }
        let now = Date()
        guard let start = ActivityLifecyclePolicy.successorDate(start: current.attributes.startDate, now: now) else { return }
        let foreground = maySchedule()
        let snapshot = placeholder()
        let content = ActivityContent(state: snapshot, staleDate: max(start, snapshot.privacy?.staleDate ?? start), relevanceScore: 0)
        var match: Session?
        var superseded: [Session] = []
        for session in pending {
            let sameCover = session.content.state.privacy?.cover == snapshot.privacy?.cover
            if match == nil, ActivityLifecyclePolicy.reusePending(start: session.attributes.startDate,
                target: start, sameCover: sameCover, foreground: foreground) {
                match = session
            } else if maySchedule() {
                if sameCover {
                    superseded.append(session)
                } else {
                    // A removed image must not be shown if registering its replacement fails.
                    await session.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        func retireSuperseded() async {
            for session in superseded where session.activityState == .pending {
                await session.end(nil, dismissalPolicy: .immediate)
            }
        }
        if let match {
            await retireSuperseded()
            let previous = scheduled?.id == match.id ? lastSubmitted : match.content.state
            observe(match, onStart: onStart)
            if previous != snapshot, match.activityState == .pending {
                await match.update(content)
                lastSubmitted = snapshot
            }
            return
        }
        guard maySchedule(), now >= retryAfter, Date() < start, PrivacyPreference.scheduledHandoffEnabled,
              current.activityState == .active || current.activityState == .stale else { return }
        do {
            let session = try Session.request(attributes: .init(startDate: start),
                content: content,
                pushType: nil, style: .standard,
                alertConfiguration: .init(title: "hiro", body: "", sound: .default), start: start)
            observe(session, onStart: onStart)
            lastSubmitted = snapshot
            await retireSuperseded()
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

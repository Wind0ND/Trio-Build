import Combine
import Foundation
import LoopKit
import Swinject

/// Escalating watchdog for a stalled loop. On every successful loop the
/// pending alarms are retracted and a fresh ladder is armed: a Time-Sensitive
/// warning at 20, 40, 60, 80 and 100 minutes, then a Critical alarm at 120.
///
/// The whole ladder is armed up front rather than re-armed as each one fires.
/// `Alert.Trigger.delayed(interval:)` becomes a `UNTimeIntervalNotification-
/// Trigger`, so the OS owns every step and the Critical alarm still arrives
/// when iOS has suspended Trio — which is the overnight device-failure case
/// the Critical tier exists for. Re-arming as a chain, or counting loop
/// invocations, would both stop dead the moment the app stops running.
///
/// A loop that recovers at any point retracts the remaining steps, so a brief
/// connectivity drop never reaches Critical.
///
/// Replaces the legacy `scheduleMissingLoopNotifiactions` direct-UN path
/// in `BaseUserNotificationsManager`. The alert now flows through
/// `TrioAlertManager` and inherits tier config from Device Alarms
/// (Critical tier by default).
final class NotLoopingMonitor: Injectable {
    @Injected() private var apsManager: APSManager!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!

    private var lastLoopDate = Date()
    private var hasLoopAnchor = false
    private var remindersEnabled = true
    private var hasReceivedPreference = false
    private var lastDosingMode: DosingMode?
    private let alarmLock = NSRecursiveLock()

    /// Minutes of staleness for each Time-Sensitive warning step.
    private static let warningMinutes: [Int] = [20, 40, 60, 80, 100]

    /// Minutes of staleness before the alarm escalates to Critical. Two hours
    /// of no automated dosing, which is the window discussed for onset of harm
    /// from undelivered insulin.
    private static let criticalMinutes: Int = 120

    /// Critical escalation. Keeps the bare identifier so existing Critical
    /// tier configuration carries over.
    private static let alertID = Alert.Identifier(
        managerIdentifier: "trio.aps",
        alertIdentifier: "loop.notActive"
    )

    /// One identifier per warning step — a single identifier cannot hold more
    /// than one pending notification, the later `add` would replace the earlier.
    private static func warningID(_ step: Int) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: "loop.notActive.w\(step)")
    }

    private static var allIDs: [Alert.Identifier] {
        [alertID] + warningMinutes.indices.map { warningID($0 + 1) }
    }

    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        lastLoopDate = apsManager.lastLoopDate
        lastDosingMode = settingsManager.settings.dosingMode
        hasLoopAnchor = true
        subscribe(to: apsManager.lastLoopDateSubject.eraseToAnyPublisher())
        subscribe(to: HiroLoopReminderPreferences.shared.$enabled.eraseToAnyPublisher())
        broadcaster.register(SnoozeObserver.self, observer: self)
        broadcaster.register(SettingsObserver.self, observer: self)
    }

    /// Publisher-only seam for tests: assigns the alert manager directly and
    /// subscribes to a supplied loop-date publisher, avoiding the need to stub
    /// the full `APSManager` protocol.
    init(loopDates: AnyPublisher<Date, Never>, trioAlertManager: TrioAlertManager,
         remindersEnabled: AnyPublisher<Bool, Never> = Just(true).eraseToAnyPublisher()) {
        self.trioAlertManager = trioAlertManager
        subscribe(to: loopDates)
        subscribe(to: remindersEnabled)
    }

    private func subscribe(to loopDates: AnyPublisher<Date, Never>) {
        loopDates
            .sink { [weak self] date in
                guard let self else { return }
                self.alarmLock.withLock {
                    self.lastLoopDate = date
                    self.hasLoopAnchor = true
                    self.rescheduleAlarm()
                }
            }
            .store(in: &subscriptions)
    }

    private func subscribe(to enabled: AnyPublisher<Bool, Never>) {
        enabled.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            self.alarmLock.withLock {
                let previous = self.remindersEnabled
                let initialized = self.hasReceivedPreference
                self.remindersEnabled = value
                self.hasReceivedPreference = true
                if !value { self.retractAll() }
                else if initialized, !previous, self.hasLoopAnchor { self.rescheduleAlarm(includeOverdue: true) }
                // An enabled initial value must preserve OS alarms and unresolved history for cold-start replay.
            }
        }.store(in: &subscriptions)
    }

    private func retractAll() {
        for identifier in Self.allIDs { trioAlertManager.retractAlert(identifier: identifier) }
    }

    private func rescheduleAlarm(includeOverdue: Bool = false) {
        alarmLock.lock()
        defer { alarmLock.unlock() }
        // Retract first — clears pending UN, modal timer, and throttler so the
        // next issueAlert isn't blocked by 5-min duplicate suppression.
        retractAll()

        // Skip when Trio isn't expected to be auto-enacting: open loop, an
        // active manual temp basal, or a suspended pump. In all three the
        // user has implicitly told Trio "don't loop right now"; a "Not
        // Looping" alarm would just be noise. nil injection (publisher-only
        // test seam) passes so the existing tests still exercise the
        // retract/reschedule plumbing.
        guard hasLoopAnchor, remindersEnabled,
              settingsManager?.settings.dosingMode.automation != AutomationLevel.off,
              apsManager?.isManualTempBasal != true,
              apsManager?.isSuspended != true
        else { return }

        let now = Date()
        for (index, minutes) in Self.warningMinutes.enumerated() {
            issue(identifier: Self.warningID(index + 1), after: minutes, level: .timeSensitive, now: now)
        }
        issue(identifier: Self.alertID, after: Self.criticalMinutes, level: .critical, now: now)
        if includeOverdue {
            let elapsedMinutes = now.timeIntervalSince(lastLoopDate) / 60
            if elapsedMinutes >= Double(Self.criticalMinutes) {
                issue(identifier: Self.alertID, after: Self.criticalMinutes, level: .critical, now: now, allowOverdue: true)
            } else if let index = Self.warningMinutes.lastIndex(where: { Double($0) <= elapsedMinutes }) {
                issue(identifier: Self.warningID(index + 1), after: Self.warningMinutes[index], level: .timeSensitive,
                      now: now, allowOverdue: true)
            }
        }
    }

    /// The catalog decides the interruption level for `trio.aps` alerts, so the
    /// level passed here only matters if the entry is ever removed.
    ///
    /// Steps are measured from the last successful loop, not from `now`, so a
    /// mid-window re-arm keeps the original schedule. A step whose moment has
    /// already passed is skipped rather than fired late.
    private func issue(identifier: Alert.Identifier, after minutes: Int, level: Alert.InterruptionLevel, now: Date,
                       allowOverdue: Bool = false) {
        let fireDate = lastLoopDate.addingTimeInterval(TimeInterval(minutes * 60))
        let remaining = fireDate.timeIntervalSince(now)
        guard remaining > 0 || allowOverdue else { return }
        let content = Alert.Content(
            title: String(localized: "Loop Execution Overdue"),
            body: String(
                format: String(localized: "Last loop was more than %d min ago"),
                minutes
            ),
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: identifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: remaining > 0 ? .delayed(interval: remaining) : .immediate,
            interruptionLevel: level,
            sound: .sound(name: "honk.caf")
        )
        trioAlertManager.issueAlert(alert)
    }
}

extension NotLoopingMonitor: SnoozeObserver {
    /// A snooze clears pending non-critical notifications wholesale, which
    /// would drop ladder steps scheduled past the end of the window as well as
    /// the ones inside it. Re-arm from the same anchor; `TrioAlertManager`
    /// drops the steps that fall inside the window and keeps the rest.
    @MainActor func snoozeDidChange(_: Date) {
        alarmLock.withLock {
            guard remindersEnabled, hasLoopAnchor else { return }
            // Snooze clears warning notifications; preserve critical alarms and their history.
            let now = Date()
            for (index, minutes) in Self.warningMinutes.enumerated() {
                issue(identifier: Self.warningID(index + 1), after: minutes, level: .timeSensitive, now: now)
            }
        }
    }
}

extension NotLoopingMonitor: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        alarmLock.withLock {
            let previous = lastDosingMode
            lastDosingMode = settings.dosingMode
            guard let previous, previous != settings.dosingMode else { return }
            if settings.dosingMode.automation == .off { retractAll() }
            else if previous.automation == .off, remindersEnabled, hasLoopAnchor { rescheduleAlarm(includeOverdue: true) }
        }
    }
}

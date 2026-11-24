import Combine
import Foundation
import LoopKit
import Swinject
import PrivacyKit
import UIKit
import UserNotifications

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
    @Injected() private var deviceDataManager: DeviceDataManager!

    private var lastLoopDate = Date()
    private var hasLoopAnchor = false
    private var remindersEnabled = true
    private var hasReceivedPreference = false
    private var lastDosingMode: DosingMode?
    private let alarmLock = NSRecursiveLock()
    private var window = HiroLoopReminderWindow()
    private var now: () -> Date = Date.init
    private var suspended = false
    private var reconciliationInFlight = false

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
        window = HiroLoopReminderWindow(defaults: .standard)
        let manualChanged = window.setManualTempBasal(apsManager.isManualTempBasal, at: now())
        suspended = apsManager.isSuspended
        // No successful loop yet: start only this reminder's local window now. Never change
        // APS's real success time or turn a brand-new setup into an immediate two-hour alert.
        lastLoopDate = window.anchor(lastSuccess: apsManager.lastLoopDate) == .distantPast ? now() : apsManager.lastLoopDate
        lastDosingMode = settingsManager.settings.dosingMode
        hasLoopAnchor = true
        subscribe(to: apsManager.lastLoopDateSubject.eraseToAnyPublisher())
        subscribe(to: HiroLoopReminderPreferences.shared.$enabled.eraseToAnyPublisher())
        subscribe(toManualBasal: deviceDataManager.manualTempBasal.receive(on: DispatchQueue.main).eraseToAnyPublisher())
        subscribe(toSuspended: deviceDataManager.suspended.receive(on: DispatchQueue.main).eraseToAnyPublisher())
        broadcaster.register(SnoozeObserver.self, observer: self)
        broadcaster.register(SettingsObserver.self, observer: self)
        if !expectsAutomaticDosing { retractAll() }
        else if manualChanged { rescheduleAlarm() }
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            Foundation.NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.requestReconciliation() }.store(in: &subscriptions)
        }
        // loadServices replays retained foreground alerts immediately after this init.
        DispatchQueue.main.async { [weak self] in self?.requestReconciliation() }
    }

    /// Publisher-only seam for tests: assigns the alert manager directly and
    /// subscribes to a supplied loop-date publisher, avoiding the need to stub
    /// the full `APSManager` protocol.
    init(loopDates: AnyPublisher<Date, Never>, trioAlertManager: TrioAlertManager,
         remindersEnabled: AnyPublisher<Bool, Never> = Just(true).eraseToAnyPublisher(),
         manualTempBasal: AnyPublisher<Bool, Never> = Empty().eraseToAnyPublisher(),
         suspended: AnyPublisher<Bool, Never> = Empty().eraseToAnyPublisher(),
         window: HiroLoopReminderWindow = HiroLoopReminderWindow(), now: @escaping () -> Date = Date.init,
         initialLoopDate: Date? = nil) {
        self.trioAlertManager = trioAlertManager
        self.window = window
        self.now = now
        if let initialLoopDate { lastLoopDate = initialLoopDate; hasLoopAnchor = true }
        subscribe(to: loopDates)
        subscribe(to: remindersEnabled)
        subscribe(toManualBasal: manualTempBasal)
        subscribe(toSuspended: suspended)
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

    private var expectsAutomaticDosing: Bool {
        let mode = settingsManager?.settings.dosingMode ?? lastDosingMode
        return mode?.automation != AutomationLevel.off && !window.manualActive && !suspended
    }

    private func subscribe(toManualBasal publisher: AnyPublisher<Bool, Never>) {
        publisher.sink { [weak self] active in
            guard let self else { return }
            self.alarmLock.withLock {
                guard self.window.setManualTempBasal(active, at: self.now()) else { return }
                if active { self.retractAll() }
                else { self.rescheduleAlarm() }
                DiagnosticEventStore.shared.record(feature: "loop", stage: "reminder", outcome: active ? "paused" : "resumed")
            }
        }.store(in: &subscriptions)
    }

    private func subscribe(toSuspended publisher: AnyPublisher<Bool, Never>) {
        publisher.sink { [weak self] value in
            guard let self else { return }
            self.alarmLock.withLock {
                guard value != self.suspended else { return }
                self.suspended = value
                if value { self.retractAll() }
                else if !self.window.manualActive {
                    self.window.beginRecovery(at: self.now())
                    self.rescheduleAlarm()
                }
            }
        }.store(in: &subscriptions)
    }

    private func retractAll() {
        for identifier in Self.allIDs { trioAlertManager.retractAlert(identifier: identifier) }
    }

    private func requestReconciliation() {
        let anchor = alarmLock.withLock { () -> Date? in
            guard !reconciliationInFlight, hasLoopAnchor, window.hasRecoveryWindow,
                  remindersEnabled, expectsAutomaticDosing else { return nil }
            reconciliationInFlight = true
            return window.anchor(lastSuccess: lastLoopDate)
        }
        guard let anchor else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.alarmLock.withLock { self.reconciliationInFlight = false } }
            let center = UNUserNotificationCenter.current()
            let requests = await center.pendingNotificationRequests()
            for note in await center.deliveredNotifications() { HiroAlertJournal.shared.observedNotification(note) }
            guard !HiroAlertJournal.shared.unavailable else { return }
            let journal = HiroAlertJournal.shared.recent()
            var pending: [String: Date] = [:]
            for request in requests {
                if let date = request.trigger?.nextTriggerDate() { pending[request.identifier] = date }
                else if let raw = request.content.userInfo[HiroAlertJournal.occurrenceKey] as? String,
                        let occurrence = UUID(uuidString: raw),
                        let entry = journal.first(where: { $0.id == occurrence }) {
                    pending[request.identifier] = entry.scheduledFor ?? entry.issuedAt
                }
            }
            self.reconcileReminders(pending: pending, journal: journal, expectedAnchor: anchor)
        }
    }

    func reconcileReminders(pending: [String: Date], journal: [JournalAlert], expectedAnchor: Date) {
        alarmLock.withLock {
            guard hasLoopAnchor, window.hasRecoveryWindow, remindersEnabled, expectsAutomaticDosing,
                  window.anchor(lastSuccess: lastLoopDate) == expectedAnchor else { return }
            let now = self.now()
            let minutes = Self.warningMinutes + [Self.criticalMinutes]
            let latestDue = minutes.lastIndex { expectedAnchor.addingTimeInterval(Double($0 * 60)) <= now }
            for (index, step) in minutes.enumerated() {
                let identifier = index == Self.warningMinutes.count ? Self.alertID : Self.warningID(index + 1)
                let deadline = expectedAnchor.addingTimeInterval(Double(step * 60))
                let installed = pending[identifier.value].map { abs($0.timeIntervalSince(deadline)) < 2 } ?? false
                let observed = journal.contains {
                    $0.source == identifier.managerIdentifier && $0.kind == identifier.alertIdentifier &&
                        abs(($0.scheduledFor ?? $0.issuedAt).timeIntervalSince(deadline)) < 2 &&
                        ($0.acknowledgedAt != nil || $0.deliveredAt != nil || $0.triggeredAt != nil)
                }
                let obsoletePastStep = deadline <= now && index != latestDue
                if pending[identifier.value] != nil, !installed || observed || obsoletePastStep {
                    trioAlertManager.retractAlert(identifier: identifier)
                }
                guard !observed, !installed, !obsoletePastStep else { continue }
                issue(identifier: identifier, after: step,
                      level: index == Self.warningMinutes.count ? .critical : .timeSensitive, now: now, allowOverdue: true)
            }
        }
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
        guard hasLoopAnchor, remindersEnabled, expectsAutomaticDosing else { return }

        let now = self.now()
        for (index, minutes) in Self.warningMinutes.enumerated() {
            issue(identifier: Self.warningID(index + 1), after: minutes, level: .timeSensitive, now: now)
        }
        issue(identifier: Self.alertID, after: Self.criticalMinutes, level: .critical, now: now)
        if includeOverdue {
            let elapsedMinutes = now.timeIntervalSince(window.anchor(lastSuccess: lastLoopDate)) / 60
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
        let fireDate = window.anchor(lastSuccess: lastLoopDate).addingTimeInterval(TimeInterval(minutes * 60))
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
            sound: .sound(name: "honk.caf"),
            metadata: [HiroLoopReminderWindow.deadlineMetadataKey: .init(fireDate.timeIntervalSince1970)]
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
            guard remindersEnabled, hasLoopAnchor, expectsAutomaticDosing else { return }
            // Snooze clears warning notifications; preserve critical alarms and their history.
            let now = self.now()
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

import BackgroundKeepAliveKit
import Combine
import Foundation
import PrivacyKit
import LoopKit
import Swinject
import UIKit
import UserNotifications

protocol TrioAlertManager: AnyObject {
    func issueAlert(_ alert: Alert)
    func retractAlert(identifier: Alert.Identifier)
    /// Re-presents unacknowledged history alerts after a cold start — the
    /// in-app presentation state dies with the process, but the history
    /// entry and the OS-side notifications survive.
    func replayUnacknowledgedAlerts()

    func register(responder: AlertResponder, for managerIdentifier: String)
    func register(soundVendor: AlertSoundVendor, for managerIdentifier: String)
    func unregister(managerIdentifier: String)

    func handleAcknowledgement(identifier: Alert.Identifier)
    @MainActor func handleNotificationResponse(_ response: UNNotificationResponse)
    @MainActor func handleWatchSnooze(_ request: AlertNotificationSnooze)
    func acknowledgeAllOutstanding()
    /// Canonical snooze entry point used by every snooze surface:
    /// Snooze module, phone UN action, watch UN action, in-app banner.
    /// Persists snoozeUntilDate, mutes AlertMuter, clears any pending
    /// non-critical UNs, broadcasts `SnoozeObserver`.
    @MainActor func applySnooze(for duration: TimeInterval) async
    /// Removes pending + already-delivered non-critical user notifications
    /// posted via the new alert pipeline. Used internally when a snooze
    /// begins so previously-scheduled delayed alerts (e.g. not-looping)
    /// don't fire during the snooze window. Critical UNs are left in
    /// place — they pierce snooze by design.
    func clearPendingNonCriticalNotifications()

    var muter: AlertMuter { get }
    var modalScheduler: TrioModalAlertScheduler { get }

    func soundURL(for alert: Alert) -> URL?
}

final class BaseTrioAlertManager: TrioAlertManager, Injectable {
    private struct WeakRef {
        weak var ref: AnyObject?
    }

    static let managerIdentifier = "Trio"
    static let soundsDirectoryName = "Sounds"

    @Injected() private var alertHistoryStorage: AlertHistoryStorage!
    @Injected() private var broadcaster: Broadcaster!

    let muter: AlertMuter
    private let throttler: AlertThrottler
    private let soundLoader: AlertSoundLoader
    /// Created lazily on first main-actor access. `CriticalAlertAudioPlayer`
    /// is `@MainActor` (its `MPVolumeView` + `Timer` members require main),
    /// but `BaseTrioAlertManager.init` runs on the Swinject resolve thread.
    @MainActor private var criticalAudioPlayer: CriticalAlertAudioPlayer?
    /// The alert `criticalAudioPlayer` is sounding for. Retracting or
    /// acknowledging any other alert must leave the audio running.
    @MainActor private var criticalAudioOwner: Alert.Identifier?
    /// Preferred audible channel on iOS 26+. Falls back to `criticalAudioPlayer`
    /// when AlarmKit is unavailable or the user hasn't authorized it.
    @MainActor private var alarmScheduler: CriticalAlertAlarmScheduler?
    /// Mirror of `CriticalAlertAlarmScheduler.isAuthorizedAndAvailable`, read
    /// off the main actor so `issueAlert` can decide synchronously whether
    /// AlarmKit will sound this alert.
    @SyncAccess private var alarmKitAvailable = false
    @MainActor private var delayedAlarmOccurrences: [Alert.Identifier: String] = [:]

    let modalScheduler: TrioModalAlertScheduler
    private let userNotificationScheduler: TrioUserNotificationAlertScheduler

    private let queue = DispatchQueue(label: "BaseTrioAlertManager.queue")
    // Retraction and replacement use the same identifier. Keep occurrence
    // validation and its acknowledgement together across producer queues.
    private let occurrenceLock = NSRecursiveLock()
    private var responders: [String: WeakRef] = [:]
    private var soundVendors: [String: WeakRef] = [:]
    private var liveAlerts: [Alert.Identifier: Alert] = [:]

    init(resolver: Resolver) {
        muter = AlertMuter()
        throttler = AlertThrottler()
        let soundsRoot = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .last!
            .appendingPathComponent(Self.soundsDirectoryName, isDirectory: true)
        soundLoader = AlertSoundLoader(destination: soundsRoot)
        modalScheduler = TrioModalAlertScheduler()
        userNotificationScheduler = TrioUserNotificationAlertScheduler(
            notificationCenter: UNUserNotificationCenter.current()
        )
        injectServices(resolver)
        modalScheduler.responder = self
        userNotificationScheduler.responder = self
        // Rehydrate the in-memory mute window from the persisted snoozeUntilDate
        // so a force-quit + relaunch during an active snooze still suppresses
        // non-critical alerts until the originally-chosen end time.
        let persistedSnoozeUntil = UserDefaults.standard
            .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date
        if let until = persistedSnoozeUntil, until > Date() {
            muter.mute(for: until.timeIntervalSinceNow)
        }

        // Seed AlarmKit availability now; `didBecomeActive` refreshes it later.
        // Without this an alarm firing before the first foreground would get
        // both the notification sound and the AlarmKit alarm.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if alarmScheduler == nil { alarmScheduler = CriticalAlertAlarmScheduler() }
            alarmKitAvailable = alarmScheduler?.isAuthorizedAndAvailable ?? false
        }

        // AlarmKit's Stop button runs an AppIntent in a fresh process slice
        // with no reference to this manager, so it routes through the shared
        // bridge. Register here; taps queued before this point are flushed.
        Task { @MainActor [weak self] in
            // Stopping an AlarmKit alarm is a dismissal like any other, so it
            // snoozes rather than silencing the alarm for the whole excursion.
            CriticalAlertAcknowledgementBridge.shared.setHandler { identifier in
                self?.requestSnooze(identifier: identifier, duration: BaseTrioAlertManager.quickSnooze)
            }
        }

        // iOS doesn't fire `didReceive` on swipe for critical UNs, so we
        // can't rely on the callback for alerts that override Silence & DnD.
        // On foreground, mirror iOS: any banner whose UN is no longer in the
        // delivered list gets hidden.
        Foundation.NotificationCenter.default.addObserver(
            self,
            selector: #selector(reconcileBannersWithDeliveredNotifications),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func reconcileBannersWithDeliveredNotifications() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if alarmScheduler == nil { alarmScheduler = CriticalAlertAlarmScheduler() }
            alarmKitAvailable = alarmScheduler?.isAuthorizedAndAvailable ?? false
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            // Without authorization nothing is ever "delivered", so a missing
            // notification carries no dismissal signal — bail entirely.
            guard settings.authorizationStatus == .authorized else { return }
            center.getDeliveredNotifications { delivered in
                center.getPendingNotificationRequests { pending in
                    guard let self else { return }
                    // Delivered ∪ pending — a replayed .delayed banner may fire
                    // moments before its OS notification moves pending→delivered.
                    let knownIDs = Set(
                        (delivered.map(\.request) + pending).compactMap { request -> Alert.Identifier? in
                            let userInfo = request.content.userInfo
                            guard
                                let managerId = userInfo[AlertUserInfoKey.managerIdentifier.rawValue] as? String,
                                let alertId = userInfo[AlertUserInfoKey.alertIdentifier.rawValue] as? String
                            else { return nil }
                            return Alert.Identifier(managerIdentifier: managerId, alertIdentifier: alertId)
                        }
                    )
                    DispatchQueue.main.async {
                        let stale = self.modalScheduler.active
                            .map(\.identifier)
                            .filter { !knownIDs.contains($0) }
                        for identifier in stale {
                            // The notification is gone from Notification Center —
                            // same gesture as swiping it away, so treat it as a
                            // dismissal: ack (history + device) + 15-min snooze.
                            self.requestSnooze(identifier: identifier, duration: Self.quickSnooze)
                            self.modalScheduler.unschedule(identifier: identifier)
                        }
                    }
                }
            }
        }
    }

    /// Falls back to in-process AVAudioPlayer for `.critical` alerts on
    /// builds without the Critical Alerts entitlement. iOS silently
    /// downgrades `.criticalSoundNamed` and `.defaultCritical` to a regular
    /// notification without the entitlement, which DnD / silent switch /
    /// Focus modes then mute — dangerous for an overnight urgent-low.
    /// `.playback` audio session bypasses those.
    ///
    /// Called on an actual fire. A delayed alarm already owned by AlarmKit
    /// needs no second audible channel when its in-app timer also fires.
    private func playCriticalAudioFallbackIfNeeded(_ alert: Alert) {
        guard alert.interruptionLevel == .critical else { return }
        // Honor `playsSound: false` (alert was issued with sound: nil) —
        // user explicitly opted out of audio on this alarm.
        guard let soundName = alert.sound?.filename else { return }
        Task { @MainActor in
            guard isCurrentOccurrence(alert) else { return }
            if let occurrence = alert.metadata?[HiroAlertJournal.occurrenceKey]?.wrapped as? String,
               delayedAlarmOccurrences[alert.identifier] == occurrence { return }
            // AlarmKit pierces silent/Focus and survives app suspension.
            if alarmScheduler == nil { alarmScheduler = CriticalAlertAlarmScheduler() }
            let scheduled = alarmScheduler?.scheduleAlarm(for: alert, onScheduleFailure: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isCurrentOccurrence(alert) else { return }
                    self.playAudioFallback(soundNamed: soundName, for: alert.identifier)
                }
            }) ?? false
            guard !scheduled else { return }
            // Fallback: in-process audio. Only sounds while Trio is running.
            playAudioFallback(soundNamed: soundName, for: alert.identifier)
        }
    }

    private func isCurrentOccurrence(_ alert: Alert) -> Bool {
        guard let occurrence = alert.metadata?[HiroAlertJournal.occurrenceKey]?.wrapped as? String else { return false }
        return occurrenceLock.perform {
            liveAlerts[alert.identifier]?.metadata?[HiroAlertJournal.occurrenceKey]?.wrapped as? String == occurrence
        }
    }

    @MainActor private func armDelayedAlarm(_ alert: Alert, fireDate: Date, occurrence: String, revision: UInt64) {
        guard isCurrentOccurrence(alert), fireDate > Date() else { return }
        if alarmScheduler == nil { alarmScheduler = CriticalAlertAlarmScheduler() }
        let accepted = alarmScheduler?.scheduleAlarm(for: alert, at: fireDate, onScheduled: {
            guard self.isCurrentOccurrence(alert) else { return }
            PrivacyNotificationLifecycle.silencePending(identifier: alert.identifier.value, occurrence: occurrence, revision: revision,
                                                       fireDate: fireDate, center: .current())
        }, onScheduleFailure: {
            if self.delayedAlarmOccurrences[alert.identifier] == occurrence {
                self.delayedAlarmOccurrences.removeValue(forKey: alert.identifier)
            }
        }) ?? false
        if accepted { delayedAlarmOccurrences[alert.identifier] = occurrence }
    }

    @MainActor private func playAudioFallback(soundNamed soundName: String, for identifier: Alert.Identifier) {
        if criticalAudioPlayer == nil { criticalAudioPlayer = CriticalAlertAudioPlayer() }
        criticalAudioOwner = identifier
        criticalAudioPlayer?.play(soundNamed: soundName)
    }

    @MainActor private func stopCriticalAudio(for identifier: Alert.Identifier) {
        guard criticalAudioOwner == identifier else { return }
        criticalAudioOwner = nil
        criticalAudioPlayer?.stop()
    }

    // MARK: - Issue / Retract

    func issueAlert(_ alert: Alert) {
        occurrenceLock.lock()
        defer { occurrenceLock.unlock() }
        info(.alerts, "Alert \(alert.identifier.value) issued, level \(alert.interruptionLevel)")

        let now = Date()
        let fireDate: Date
        switch alert.trigger {
        case .immediate: fireDate = now
        case let .delayed(interval),
             let .repeating(interval): fireDate = now.addingTimeInterval(interval)
        }

        // Catalog-known alerts (pump, CGM lifecycle, Trio algorithm) get the
        // user's Device Alarms tier config applied — tone, Play Sound,
        // Override Silence & Focus, day/night window. Everything else
        // (Trio-internal glucose, owned by `GlucoseAlertCoordinator`) is
        // passed through with the level and sound its producer chose.
        var effective: Alert
        if let entry = AlertCatalogRegistry.lookup(alert.identifier) {
            // Tier comes from the catalog, never from the post-override
            // level: a Time-Sensitive alarm with "Override Silence & Focus"
            // on still snoozes and configures as Time-Sensitive.
            guard let tier = DeviceAlertSeverity(level: entry.interruptionLevel) else { return }

            // Per-tier snooze. Critical tier ignores snooze.
            if tier != .critical, DeviceAlertsStore.shared.isTierSnoozed(tier, at: fireDate) {
                debug(.alerts, "Alert \(alert.identifier.value) dropped, tier \(tier) snoozed")
                return
            }
            // nil = every variant in the tier disabled, user opted out.
            let isNight = GlucoseAlertsStore.shared.configuration.isNight(at: now)
            guard let config = DeviceAlertsStore.shared.config(for: tier, at: now, isNight: isNight) else {
                debug(.alerts, "Alert \(alert.identifier.value) dropped, all variants in tier \(tier) disabled")
                return
            }
            effective = Self.applyDeviceSeverityConfig(config, entry: entry, to: alert)
        } else {
            effective = alert
        }

        // Critical alerts pierce the snooze/mute window. Everything else is
        // suppressed entirely while muted (no modal, no UN sound, no critical
        // audio fallback).
        if effective.interruptionLevel != .critical, muter.shouldMute(at: fireDate) {
            debug(.alerts, "Alert \(effective.identifier.value) muted, snooze window active")
            return
        }
        guard throttler.shouldDeliver(effective) else {
            debug(.alerts, "Alert \(effective.identifier.value) throttled")
            return
        }
        var metadata = effective.metadata ?? [:]
        let occurrence = UUID()
        metadata[HiroAlertJournal.occurrenceKey] = .init(occurrence.uuidString)
        effective = Alert(identifier: effective.identifier, foregroundContent: effective.foregroundContent,
                          backgroundContent: effective.backgroundContent, trigger: effective.trigger,
                          interruptionLevel: effective.interruptionLevel, sound: effective.sound,
                          metadata: metadata, categoryIdentifier: effective.categoryIdentifier)
        let tracked = effective
        liveAlerts[tracked.identifier] = tracked
        recordIssued(effective)
        modalScheduler.schedule(effective)
        let soundURL = soundLoader.url(for: effective)
        let criticalTone = effective.interruptionLevel == .critical && effective.sound?.filename != nil
        switch effective.trigger {
        case .immediate:
            userNotificationScheduler.schedule(effective, soundURL: soundURL, silenced: criticalTone && alarmKitAvailable)
            HiroAlertJournal.shared.triggered(id: occurrence)
            playCriticalAudioFallbackIfNeeded(effective)
        case .delayed where criticalTone:
            // Arm an audible OS notification first. Only a successful AlarmKit
            // submission can take over its sound, and both target the same date.
            userNotificationScheduler.schedule(tracked, soundURL: soundURL) { [weak self] revision in
                Task { @MainActor in self?.armDelayedAlarm(tracked, fireDate: fireDate, occurrence: occurrence.uuidString, revision: revision) }
            }
        default:
            userNotificationScheduler.schedule(effective, soundURL: soundURL)
        }
    }

    /// Overlays the user's Device Alarms tier config onto a catalog-known
    /// alert. Plugins issue their alerts without a sound, so this is what
    /// gives a pump/CGM alarm the tone the user picked — and what engages
    /// `CriticalAlertAudioPlayer`, which needs a filename to play.
    /// Static so tests can exercise it without the Swinject graph.
    static func applyDeviceSeverityConfig(
        _ config: DeviceAlertSeverityConfig,
        entry: Alert.CatalogEntry,
        to alert: Alert
    ) -> Alert {
        Alert(
            identifier: alert.identifier,
            foregroundContent: alert.foregroundContent,
            backgroundContent: alert.backgroundContent,
            trigger: alert.trigger,
            // Escalate only — the catalog level is the floor, so the override
            // toggle can't demote a Critical alarm or promote a Normal one
            // past what the catalog says it is.
            interruptionLevel: config.overridesSilenceAndDND ? .critical : entry.interruptionLevel,
            sound: config.playsSound ? .sound(name: config.soundFilename) : nil,
            metadata: alert.metadata,
            categoryIdentifier: alert.categoryIdentifier
        )
    }

    func retractAlert(identifier: Alert.Identifier) {
        occurrenceLock.lock()
        defer { occurrenceLock.unlock() }
        HiroAlertJournal.shared.resolve(source: identifier.managerIdentifier, kind: identifier.alertIdentifier)
        liveAlerts.removeValue(forKey: identifier)
        modalScheduler.unschedule(identifier: identifier)
        userNotificationScheduler.unschedule(identifier: identifier)
        throttler.reset(identifier: identifier)
        Task { @MainActor in
            stopCriticalAudio(for: identifier)
            delayedAlarmOccurrences.removeValue(forKey: identifier)
            alarmScheduler?.cancelAlarm(for: identifier)
        }
        alertHistoryStorage.removeAlert(managerIdentifier: identifier.managerIdentifier, identifier: identifier.alertIdentifier)
    }

    /// Cold-start replay. Deliberately skips `recordIssued` (entry already
    /// exists), the UN scheduler (pending/delivered notifications survive
    /// termination at OS level), the throttler (a genuine producer re-issue
    /// must still deliver fully), and critical audio.
    func replayUnacknowledgedAlerts() {
        occurrenceLock.lock()
        defer { occurrenceLock.unlock() }
        let now = Date()
        let entries = AlertColdStartReplay.newestPerIdentifier(
            alertHistoryStorage.unacknowledgedAlertsWithinLast24Hours()
        )
        let muted = muter.shouldMute(at: now)
        for entry in entries {
            switch AlertColdStartReplay.decision(
                for: entry,
                now: now,
                isTierSnoozed: { DeviceAlertsStore.shared.isTierSnoozed($0, at: now) },
                isMuted: muted
            ) {
            case let .replay(alert):
                debug(.alerts, "Alert \(alert.identifier.value) replayed after launch")
                liveAlerts[alert.identifier] = alert
                modalScheduler.schedule(alert)
            case .acknowledgeSilently:
                alertHistoryStorage.acknowledgeAlert(entry.issuedDate, nil)
            case .skip:
                break
            }
        }
    }

    // MARK: - Acknowledgement

    func handleAcknowledgement(identifier: Alert.Identifier) {
        occurrenceLock.lock()
        defer { occurrenceLock.unlock() }
        HiroAlertJournal.shared.acknowledge(source: identifier.managerIdentifier, kind: identifier.alertIdentifier)
        modalScheduler.unschedule(identifier: identifier)
        userNotificationScheduler.unschedule(identifier: identifier)
        Task { @MainActor in
            stopCriticalAudio(for: identifier)
            delayedAlarmOccurrences.removeValue(forKey: identifier)
            alarmScheduler?.cancelAlarm(for: identifier)
        }
        // All matching entries — replay + a genuine re-issue can coexist.
        alertHistoryStorage.acknowledgeAllEntries(
            managerIdentifier: identifier.managerIdentifier,
            alertIdentifier: identifier.alertIdentifier
        )
        liveAlerts.removeValue(forKey: identifier)
        acknowledgeOnDevice(identifier: identifier)
    }

    /// Forwards the user's response to the issuing device manager — pump alerts
    /// need this to also clear the alert on the device itself (e.g. pod beeps).
    /// Only device managers register as responders (currently just the pump
    /// manager), so Trio-internal alerts (glucose, not-looping, algorithm)
    /// never match and bail out here.
    private func acknowledgeOnDevice(identifier: Alert.Identifier) {
        guard let responder = queue.sync(execute: { responders[identifier.managerIdentifier]?.ref as? AlertResponder })
        else { return }
        Task {
            do {
                try await responder.acknowledgeAlert(alertIdentifier: identifier.alertIdentifier)
            } catch {
                warning(.alerts, "Acknowledging alert \(identifier.value) on device failed", error: error)
            }
        }
    }

    /// What a dismissal buys when the user didn't name a duration.
    static let quickSnooze: TimeInterval = NotificationResponseAction.snooze15.duration

    /// How long a notification response snoozes for: the action's own
    /// duration if the user picked one, the quick 15 minutes for a swipe, a
    /// tap or OK. Extracted for unit testing.
    static func snoozeDuration(forActionIdentifier actionIdentifier: String) -> TimeInterval {
        NotificationResponseAction(rawValue: actionIdentifier)?.duration ?? quickSnooze
    }

    @MainActor func handleNotificationResponse(_ response: UNNotificationResponse) {
        let content = response.notification.request.content
        let userInfo = content.userInfo
        if userInfo[AlertUserInfoKey.occurrence.rawValue] != nil {
            let action = NotificationResponseAction(rawValue: response.actionIdentifier) ?? .snooze15
            guard let request = AlertNotificationSnooze(content: content, action: action, at: Date()) else { return }
            applyNotificationSnooze(request, allowGlobalFallback: true)
            return
        }
        guard
            let managerId = userInfo[AlertUserInfoKey.managerIdentifier.rawValue] as? String,
            let alertId = userInfo[AlertUserInfoKey.alertIdentifier.rawValue] as? String
        else { return }
        let identifier = Alert.Identifier(managerIdentifier: managerId, alertIdentifier: alertId)

        // Clearing an alert is always a snooze, never a permanent dismissal:
        // the chosen duration if the user picked one, the quick 15 minutes for
        // a swipe, a tap or the OK button. The in-app banner already works
        // this way; only the notification didn't, so acknowledging a High
        // meant never hearing it again for that whole excursion.
        //
        // The snooze path acknowledges too, so history and the issuing device
        // still see the user's response.
        let category = NotificationCategoryIdentifier.alert(isCritical: response.notification.request.content.interruptionLevel == .critical,
            slug: alertId)
        let duration = category.limitSnooze(Self.snoozeDuration(forActionIdentifier: response.actionIdentifier))
        modalScheduler.snooze(identifier: identifier, duration: duration)
        userNotificationScheduler.unschedule(identifier: identifier)
    }

    func acknowledgeAllOutstanding() {
        let outstanding = alertHistoryStorage.unacknowledgedAlertsWithinLast24Hours()
        for entry in outstanding {
            let identifier = Alert.Identifier(
                managerIdentifier: entry.managerIdentifier,
                alertIdentifier: entry.alertIdentifier
            )
            handleAcknowledgement(identifier: identifier)
        }
    }

    @MainActor func handleWatchSnooze(_ request: AlertNotificationSnooze) {
        applyNotificationSnooze(request, allowGlobalFallback: false)
    }

    @MainActor private func applyNotificationSnooze(_ request: AlertNotificationSnooze, allowGlobalFallback: Bool) {
        occurrenceLock.lock()
        defer { occurrenceLock.unlock() }
        let id = Alert.Identifier(managerIdentifier: request.managerIdentifier, alertIdentifier: request.alertIdentifier)
        let occurrence: UUID?
        let critical: Bool
        if let live = liveAlerts[id] {
            occurrence = (live.metadata?[HiroAlertJournal.occurrenceKey]?.wrapped as? String).flatMap(UUID.init(uuidString:))
            critical = live.interruptionLevel == .critical
        } else {
            // The system notification survives process death. Inspect the
            // newest occurrence including closed ones; an older pending row
            // must not become eligible just because its replacement was closed.
            guard let newest = Self.latestOpenOccurrence(for: id, in: HiroAlertJournal.shared.recent()) else { return }
            occurrence = newest
            let entry = alertHistoryStorage.unacknowledgedAlertsWithinLast24Hours().first { $0.journalOccurrenceID == newest }
            let level = entry?.primitiveInterruptionLevel.flatMap { Alert.InterruptionLevel(storedValue: NSDecimalNumber(decimal: $0)) }
            critical = (level ?? .critical) == .critical
        }
        guard let until = request.until(currentOccurrence: occurrence, isCritical: critical, now: Date()) else { return }
        requestSnooze(identifier: id, until: until, allowGlobalFallback: allowGlobalFallback)
    }

    static func latestOpenOccurrence(for id: Alert.Identifier, in rows: [JournalAlert]) -> UUID? {
        let newest = rows.filter { $0.source == id.managerIdentifier && $0.kind == id.alertIdentifier }
            .max { $0.issuedAt < $1.issuedAt }
        guard let newest, newest.acknowledgedAt == nil, newest.resolvedAt == nil, newest.cancelledAt == nil else { return nil }
        return newest.id
    }

    private func clearPendingNonCriticalNotificationsAndWait() async {
        await withCheckedContinuation { continuation in
            let center = UNUserNotificationCenter.current()
            center.getPendingNotificationRequests { requests in
                let ids = requests
                    .filter { $0.content.interruptionLevel != .critical && $0.identifier != BackgroundKeepAlive.reminderID }
                    .map(\.identifier)
                if !ids.isEmpty {
                    PrivacyNotificationLifecycle.invalidate(ids)
                    center.removePendingNotificationRequests(withIdentifiers: ids)
                }
                center.getDeliveredNotifications { delivered in
                    delivered.forEach { HiroAlertJournal.shared.observedNotification($0) }
                    let ids = delivered
                        .filter { $0.request.content.interruptionLevel != .critical }
                        .map(\.request.identifier)
                    if !ids.isEmpty {
                        PrivacyNotificationLifecycle.invalidate(ids)
                        center.removeDeliveredNotifications(withIdentifiers: ids)
                    }
                    continuation.resume()
                }
            }
        }
    }

    func clearPendingNonCriticalNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .filter { $0.content.interruptionLevel != .critical && $0.identifier != BackgroundKeepAlive.reminderID }
                .map(\.identifier)
            guard !ids.isEmpty else { return }
            PrivacyNotificationLifecycle.invalidate(ids)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.getDeliveredNotifications { delivered in
            delivered.forEach { HiroAlertJournal.shared.observedNotification($0) }
            let ids = delivered
                .filter { $0.request.content.interruptionLevel != .critical }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            PrivacyNotificationLifecycle.invalidate(ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Persisted under the same key UN reads, so a force-quit + relaunch
    /// during a snooze sees the same end-date.
    private static let snoozeUntilDateKey = BackgroundKeepAlive.globalSnoozeUntilKey
    private static let legacyGlucoseNotificationID = "Trio.glucoseNotification"

    @MainActor func applySnooze(for duration: TimeInterval) async {
        let untilDate = duration > 0 ? Date().addingTimeInterval(duration) : .distantPast
        UserDefaults.standard.set(untilDate, forKey: Self.snoozeUntilDateKey)
        // The watchdog owns its single pending notification and shifts it to
        // the end of the snooze if the outage would otherwise ring during it.
        BackgroundKeepAlive.shared.settingsChanged()

        // Legacy glucose-notification UN cleanup (the new pipeline uses
        // per-alarm identifiers; this catches anything still lingering
        // from older installs).
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.legacyGlucoseNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.legacyGlucoseNotificationID])

        if duration > 0 {
            muter.mute(for: duration)
            await clearPendingNonCriticalNotificationsAndWait()
            modalScheduler.clearNonCriticalBanners()
        } else {
            muter.unmute()
        }

        broadcaster.notify(SnoozeObserver.self, on: .main) { (observer: SnoozeObserver) in
            observer.snoozeDidChange(untilDate)
        }
    }

    // MARK: - Registry

    func register(responder: AlertResponder, for managerIdentifier: String) {
        queue.async {
            self.responders[managerIdentifier] = WeakRef(ref: responder as AnyObject)
        }
    }

    func register(soundVendor: AlertSoundVendor, for managerIdentifier: String) {
        queue.async {
            self.soundVendors[managerIdentifier] = WeakRef(ref: soundVendor as AnyObject)
        }
        soundLoader.copySounds(from: soundVendor, managerIdentifier: managerIdentifier)
    }

    func unregister(managerIdentifier: String) {
        queue.async {
            self.responders.removeValue(forKey: managerIdentifier)
            self.soundVendors.removeValue(forKey: managerIdentifier)
        }
    }

    func soundURL(for alert: Alert) -> URL? {
        soundLoader.url(for: alert)
    }

    // MARK: - Persistence bridge

    private func recordIssued(_ alert: Alert) {
        var entry = AlertEntry(
            alertIdentifier: alert.identifier.alertIdentifier,
            primitiveInterruptionLevel: alert.interruptionLevel.storedValue as? Decimal,
            issuedDate: Date(),
            managerIdentifier: alert.identifier.managerIdentifier,
            triggerType: alert.trigger.storedType,
            triggerInterval: alert.trigger.storedInterval as? Decimal,
            contentTitle: alert.foregroundContent?.title ?? alert.backgroundContent.title,
            contentBody: alert.foregroundContent?.body ?? alert.backgroundContent.body
        )
        let occurrence = (alert.metadata?[HiroAlertJournal.occurrenceKey]?.wrapped as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        entry.journalOccurrenceID = occurrence
        alertHistoryStorage.addAlert(entry)
        HiroAlertJournal.shared.issue(JournalAlert(
            id: occurrence,
            source: entry.managerIdentifier, kind: entry.alertIdentifier,
            title: entry.contentTitle ?? "", body: entry.contentBody ?? "", issuedAt: entry.issuedDate,
            scheduledFor: alert.trigger.storedInterval.map { entry.issuedDate.addingTimeInterval($0.doubleValue) }
        ))
    }
}

extension BaseTrioAlertManager: TrioModalAlertResponder, TrioUserNotificationAlertResponder {
    func requestSnooze(identifier: Alert.Identifier, duration: TimeInterval) {
        let until = duration > 0 ? Date().addingTimeInterval(duration) : .distantPast
        requestSnooze(identifier: identifier, until: until, allowGlobalFallback: true)
    }

    private func requestSnooze(identifier: Alert.Identifier, until untilDate: Date, allowGlobalFallback: Bool) {
        // Dismissal is the user's response — full ack (history + device) first.
        handleAcknowledgement(identifier: identifier)
        if let glucoseType = GlucoseAlertType(slug: identifier.alertIdentifier) {
            broadcaster.notify(GlucoseSnoozeObserver.self, on: .main) { (observer: GlucoseSnoozeObserver) in
                observer.snoozeGlucoseType(glucoseType, until: untilDate)
            }
        } else if let entry = AlertCatalogRegistry.lookup(identifier),
                  let tier = DeviceAlertSeverity(level: entry.interruptionLevel),
                  tier != .critical
        {
            guard !entry.concept.isEscalationStep else { return }
            DeviceAlertsStore.shared.snoozeTier(tier, until: untilDate)
            dismissAlertsInTier(tier, excluding: identifier)
        } else if allowGlobalFallback {
            Task { @MainActor [weak self] in
                await self?.applySnooze(for: max(0, untilDate.timeIntervalSinceNow))
            }
        }
    }

    /// Same-tier siblings visible when the user snoozes one alert get the
    /// same treatment — acknowledged (history + device), not silently
    /// retracted with their history entries deleted.
    private func dismissAlertsInTier(_ tier: DeviceAlertSeverity, excluding: Alert.Identifier) {
        let toDismiss: [Alert.Identifier] = occurrenceLock.perform {
            liveAlerts.compactMap { id, _ in
                guard id != excluding,
                      let entry = AlertCatalogRegistry.lookup(id),
                      !entry.concept.isEscalationStep,
                      DeviceAlertSeverity(level: entry.interruptionLevel) == tier
                else { return nil }
                return id
            }
        }
        for id in toDismiss {
            handleAcknowledgement(identifier: id)
        }
    }

    /// Convenience for the UN-action / Watch / Snooze-module paths that
    /// don't have an originating alert identifier — they all want global.
    func requestSnooze(duration: TimeInterval) {
        Task { @MainActor [weak self] in
            await self?.applySnooze(for: duration)
        }
    }

    func alertDidFire(_ alert: Alert) {
        if let raw = alert.metadata?[HiroAlertJournal.occurrenceKey]?.wrapped as? String,
           let id = UUID(uuidString: raw) { HiroAlertJournal.shared.triggered(id: id) }
        playCriticalAudioFallbackIfNeeded(alert)
    }

    func isAlertActive(identifier: Alert.Identifier) -> Bool {
        occurrenceLock.perform { liveAlerts[identifier] != nil }
    }

    func isSnoozeActive(at date: Date) -> Bool {
        muter.shouldMute(at: date)
    }
}

/// Observer for per-type glucose snoozes triggered from an in-app banner.
/// `GlucoseAlertCoordinator` registers and applies the snooze to its
/// `snoozedUntil` field on every matching `GlucoseAlert`.
protocol GlucoseSnoozeObserver {
    func snoozeGlucoseType(_ type: GlucoseAlertType, until: Date)
}

// MARK: - Muter

final class AlertMuter: ObservableObject {
    @Published private(set) var startDate: Date?
    @Published private(set) var duration: TimeInterval = 0

    func mute(for duration: TimeInterval, from start: Date = Date()) {
        startDate = start
        self.duration = duration
    }

    func unmute() {
        startDate = nil
        duration = 0
    }

    func shouldMute(at date: Date) -> Bool {
        guard let start = startDate else { return false }
        return date >= start && date < start.addingTimeInterval(duration)
    }

    var endsAt: Date? {
        guard let start = startDate else { return nil }
        return start.addingTimeInterval(duration)
    }
}

// MARK: - Throttler

final class AlertThrottler {
    private let queue = DispatchQueue(label: "AlertThrottler.queue")
    private var lastDelivered: [Alert.Identifier: Date] = [:]
    private let minimumInterval: TimeInterval = 5 * 60

    func shouldDeliver(_ alert: Alert) -> Bool {
        queue.sync {
            let now = Date()
            if let last = lastDelivered[alert.identifier], now.timeIntervalSince(last) < minimumInterval {
                return false
            }
            lastDelivered[alert.identifier] = now
            return true
        }
    }

    func reset(identifier: Alert.Identifier) {
        queue.sync { _ = lastDelivered.removeValue(forKey: identifier) }
    }
}

// MARK: - Sound loader

final class AlertSoundLoader {
    private let destination: URL
    private let fileManager: FileManager

    init(destination: URL, fileManager: FileManager = .default) {
        self.destination = destination
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    func copySounds(from vendor: AlertSoundVendor, managerIdentifier: String) {
        guard let sourceBase = vendor.getSoundBaseURL() else { return }
        for sound in vendor.getSounds() {
            guard let filename = sound.filename else { continue }
            let source = sourceBase.appendingPathComponent(filename)
            let dest = destination.appendingPathComponent(Self.namespaced(managerIdentifier, filename))
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if fileManager.fileExists(atPath: dest.path) { continue }
            try? fileManager.copyItem(at: source, to: dest)
        }
    }

    func url(for alert: Alert) -> URL? {
        guard let filename = alert.sound?.filename else { return nil }
        let url = destination
            .appendingPathComponent(Self.namespaced(alert.identifier.managerIdentifier, filename))
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// iOS only resolves `UNNotificationSoundName` against the flat top level of
    /// `Library/Sounds`, so vendor sounds are namespaced instead of nested.
    static func namespaced(_ managerIdentifier: String, _ filename: String) -> String {
        "\(managerIdentifier)-\(filename)"
    }
}

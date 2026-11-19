#if os(iOS)
import AVFoundation
import Foundation
import UserNotifications
import UIKit
import Combine

/// Event-driven protection, bounded source recovery and a system-owned freshness reminder.
@MainActor
public final class BackgroundKeepAlive: ObservableObject {
    public static let shared = BackgroundKeepAlive()
    public enum Status: String { case disabled, noSource, foreground, protecting, interrupted, alert, limited, failed }
    @Published public private(set) var status: Status = .foreground

    public enum SettingsKey {
        public static let mode = "backgroundKeepAlive.mode"
        public static let stallMinutes = "backgroundKeepAlive.stallMinutes"
        public static let maxSessionMinutes = "backgroundKeepAlive.maxSessionMinutes"
    }

    private enum Stage: String { case audio, reminder, data, source, lifecycle, recovery }
    private enum Outcome: String {
        case started, stopped, failed, interrupted, capped, scheduled, recovered, received, stored
        case background, foreground, requested, completed, timedOut = "timed_out", reset, overdue
    }

    public static let sourceActivity = Notification.Name("com.trio.cgm.sourceActivity")
    public struct RefreshRequest: Sendable {
        public let isCurrent: @MainActor @Sendable () -> Bool
        public let complete: @Sendable (Bool) -> Void
    }
    public typealias RefreshHandler = (RefreshRequest) -> Void

    private static let reminderID = "background-keep-alive-stall"
    private static let acknowledgedDeadlineKey = "backgroundKeepAlive.lastScheduledDeadline"
    private let notifications = UNUserNotificationCenter.current()
    private let audio = KeepAliveAudio()
    private let defaults = UserDefaults.standard
    private var policy = KeepAlivePolicy()
    private var hasSource: (() -> Bool)?
    private var refresh: RefreshHandler?
    private var privateReminderTitle: (() -> String?)?
    private var background = false
    private var playing = false
    private var alertOwnsAudio = false
    private var interruption = KeepAliveInterruptionState()
    private var capReported = false
    private var audioRetryAfter: TimeInterval = 0
    private var check: Task<Void, Never>?
    private var reminderDeadline: Date?
    private var reminderOutcome: Outcome?
    private var clearedReminder = false
    private var observers: [NSObjectProtocol] = []
    private var recentEvents: [Stage: (Outcome, Date)] = [:]
    private var refreshToken: UUID?
    private var refreshLease: UIBackgroundTaskIdentifier = .invalid
    private var refreshTimeout: Task<Void, Never>?
    private var reminderIsPrivate: Bool?

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: rawType, options: rawOptions)
            }
        })
        for name in [AVAudioSession.mediaServicesWereResetNotification, Notification.Name.AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let engineID = (note.object as? AVAudioEngine).map(ObjectIdentifier.init)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == Notification.Name.AVAudioEngineConfigurationChange,
                       engineID != self.audio.engineIdentifier || self.audio.isRunning || self.alertOwnsAudio { return }
                    self.audio.reset()
                    self.playing = false
                    self.record(.audio, .reset)
                    self.reevaluate()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: Self.sourceActivity, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteSourceActivity() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .init("com.trio.privacy.changed"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.settingsChanged() }
        })
    }

    public func configure(initialSample: Date?, hasSource: @escaping () -> Bool, refresh: RefreshHandler? = nil, privateReminderTitle: (() -> String?)? = nil) {
        self.hasSource = hasSource
        self.refresh = refresh
        self.privateReminderTitle = privateReminderTitle
        if let initialSample { policy.accept(initialSample, now: Date()) }
        notifications.removePendingNotificationRequests(withIdentifiers: ["background-keep-alive-expired"])
        reevaluate()
    }

    public func setBackground(_ value: Bool) {
        if value != background { record(.lifecycle, value ? .background : .foreground) }
        background = value
        reevaluate()
    }

    public func settingsChanged() { reevaluate() }

    public func noteSourceActivity() {
        guard hasSource?() == true else { return }
        record(.source, .received)
        reevaluate()
    }

    public func noteGlucoseSample(at timestamp: Date) {
        let now = Date()
        let configuration = configuration
        let interval = configuration.stallInterval
        let wasStale = policy.isStale(now: now, interval: interval)
        guard policy.accept(timestamp, now: now) else { return }
        record(.data, .stored)
        if !policy.isStale(now: now, interval: interval) {
            capReported = false
            if wasStale, configuration.mode != .off, hasSource?() == true {
                record(.data, .recovered)
                notifications.removeDeliveredNotifications(withIdentifiers: [Self.reminderID])
            }
        }
        reevaluate()
    }

    public func yieldAudioToAlert() {
        alertOwnsAudio = true
        stopAudio(.stopped)
    }

    public func alertAudioDidEnd() {
        guard alertOwnsAudio else { return }
        alertOwnsAudio = false
        reevaluate()
    }

    private var configuration: KeepAlivePolicy.Configuration {
        .init(
            mode: defaults.string(forKey: SettingsKey.mode),
            stallMinutes: defaults.integer(forKey: SettingsKey.stallMinutes),
            maxSessionMinutes: defaults.integer(forKey: SettingsKey.maxSessionMinutes)
        )
    }

    private func reevaluate() {
        guard let hasSource else { return }
        interruption.wake(otherAudio: AVAudioSession.sharedInstance().isOtherAudioPlaying)
        check?.cancel()
        check = nil
        let configuration = configuration
        guard configuration.mode != .off, hasSource() else {
            status = configuration.mode == .off ? .disabled : .noSource
            policy.endMonitoring()
            clearReminder()
            stopAudio(.stopped)
            finishRefresh(.stopped)
            return
        }

        let now = Date()
        policy.beginMonitoring(at: now)
        let deadline = policy.deadline(interval: configuration.stallInterval)
        if let deadline { scheduleReminder(for: deadline, now: now, interval: configuration.stallInterval) }

        let uptime = ProcessInfo.processInfo.systemUptime
        let stale = policy.isStale(now: now, interval: configuration.stallInterval)
        if stale { record(.data, .overdue); requestRefresh(now: now) }
        var capped = false
        if configuration.mode == .smart {
            capped = policy.recoveryCapped(stale: stale && background, uptime: uptime, limit: configuration.capInterval)
            if !stale { capReported = false }
            if capped {
                if !capReported {
                    capReported = true
                    record(.audio, .capped)
                }
            }
        }

        guard policy.wantsAudio(configuration: configuration, now: now, background: background,
                                blocked: alertOwnsAudio || interruption.blocked, capped: capped) else {
            status = !background ? .foreground : (alertOwnsAudio ? .alert : (interruption.blocked ? .interrupted : .limited))
            stopAudio(.stopped)
            // Timers are only opportunistic; Bluetooth wakes and foreground events also reevaluate.
            if background { armCheck(after: 60) }
            return
        }

        guard uptime >= audioRetryAfter else {
            armCheck(after: audioRetryAfter - uptime)
            return
        }
        if !audio.isRunning {
            audio.stop()
            guard audio.start() else {
                status = .failed
                if audioRetryAfter == 0 { record(.audio, .failed) }
                playing = false
                audioRetryAfter = uptime + 60
                armCheck(after: 60)
                return
            }
            playing = true
            audioRetryAfter = 0
            record(.audio, .started)
        }
        status = .protecting

        armCheck(after: 60)
    }

    private func requestRefresh(now: Date) {
        guard let refresh, refreshToken == nil, policy.reserveRefresh(now: now) else { return }
        let token = UUID()
        refreshToken = token
        record(.recovery, .requested)
        refreshLease = UIApplication.shared.beginBackgroundTask(withName: "CGM recovery and presentation") { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.refreshToken == token else { return }
                self?.finishRefresh(.timedOut)
            }
        }
        refreshTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard self?.refreshToken == token else { return }
            self?.finishRefresh(.timedOut)
        }
        let request = RefreshRequest(
            isCurrent: { [weak self] in self?.refreshToken == token },
            complete: { [weak self] success in
                Task { @MainActor [weak self] in
                    guard self?.refreshToken == token else { return }
                    self?.finishRefresh(success ? .completed : .failed)
                }
            }
        )
        refresh(request)
    }

    private func finishRefresh(_ outcome: Outcome) {
        guard refreshToken != nil else { return }
        refreshToken = nil
        refreshTimeout?.cancel()
        refreshTimeout = nil
        if refreshLease != .invalid {
            UIApplication.shared.endBackgroundTask(refreshLease)
            refreshLease = .invalid
        }
        record(.recovery, outcome)
    }

    private func armCheck(after delay: TimeInterval) {
        // This timer can run only when iOS gives the process execution time.
        check = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, delay))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }

    private func scheduleReminder(for deadline: Date, now: Date, interval: TimeInterval) {
        let privateTitle = privateReminderTitle?()
        let isPrivate = privateTitle != nil
        let privacyChanged = reminderIsPrivate.map { $0 != isPrivate } ?? false
        if privacyChanged {
            reminderDeadline = nil
            // Remove already-public text silently; replacing a future pending request keeps its original deadline.
            notifications.removeDeliveredNotifications(withIdentifiers: [Self.reminderID])
            if deadline <= now { notifications.removePendingNotificationRequests(withIdentifiers: [Self.reminderID]) }
        }
        reminderIsPrivate = isPrivate
        if let current = reminderDeadline, current == deadline || (current <= now && deadline <= now) { return }
        if !KeepAliveReminderPolicy.shouldNotify(deadline: deadline, now: now,
            acknowledged: defaults.object(forKey: Self.acknowledgedDeadlineKey) as? Date, privacyChanged: privacyChanged) {
            reminderDeadline = deadline
            return
        }
        reminderDeadline = deadline
        clearedReminder = false

        let content = UNMutableNotificationContent()
        let minutes = Int(interval / 60)
        content.title = String(localized: "Glucose Data Interrupted", bundle: .main)
        content.body = String(localized: "No new glucose readings for \(minutes) minutes. Open Trio and check the CGM connection.", bundle: .main)
        if let privateTitle { content.title = privateTitle; content.body = "" }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSince(now)), repeats: false)
        let request = UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: trigger)

        // Adding with the same identifier replaces a pending request atomically.
        notifications.add(request) { [weak self] error in
            let success = error == nil
            Task { @MainActor [weak self] in
                guard let self, self.reminderDeadline == deadline else { return }
                if success {
                    self.defaults.set(deadline, forKey: Self.acknowledgedDeadlineKey)
                } else {
                    self.reminderDeadline = nil
                }
                let outcome: Outcome = success ? .scheduled : .failed
                if self.reminderOutcome != outcome {
                    self.reminderOutcome = outcome
                    self.record(.reminder, outcome)
                }
            }
        }
    }

    private func clearReminder() {
        guard !clearedReminder else { return }
        reminderDeadline = nil
        reminderOutcome = nil
        clearedReminder = true
        defaults.removeObject(forKey: Self.acknowledgedDeadlineKey)
        notifications.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        notifications.removeDeliveredNotifications(withIdentifiers: [Self.reminderID])
    }

    private func stopAudio(_ outcome: Outcome, report: Bool = true) {
        audio.stop()
        if playing, report { record(.audio, outcome) }
        playing = false
    }

    private func handleInterruption(type: UInt, options: UInt) {
        switch AVAudioSession.InterruptionType(rawValue: type) {
        case .began:
            interruption.began()
            stopAudio(.interrupted)
            reevaluate()
        case .ended:
            interruption.ended(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
                               otherAudio: AVAudioSession.sharedInstance().isOtherAudioPlaying)
            reevaluate()
        default: break
        }
    }

    private func record(_ stage: Stage, _ outcome: Outcome) {
        let now = Date()
        if let (previous, date) = recentEvents[stage], previous == outcome, now.timeIntervalSince(date) < 300 { return }
        recentEvents[stage] = (outcome, now)
        NotificationCenter.default.post(name: .init("com.trio.diagnostics.event"), object: nil, userInfo: [
            "schema": 1, "feature": "keep_alive", "stage": stage.rawValue, "outcome": outcome.rawValue
        ])
    }
}
#endif

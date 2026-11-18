#if os(iOS)
import AVFoundation
import Foundation
import UserNotifications

/// Coordinates an optional audio fallback and a system-owned CGM freshness reminder.
@MainActor
public final class BackgroundKeepAlive {
    public static let shared = BackgroundKeepAlive()

    public enum SettingsKey {
        public static let mode = "backgroundKeepAlive.mode"
        public static let stallMinutes = "backgroundKeepAlive.stallMinutes"
        public static let maxSessionMinutes = "backgroundKeepAlive.maxSessionMinutes"
    }

    private enum Stage: String { case audio, reminder, data }
    private enum Outcome: String { case started, stopped, failed, interrupted, capped, scheduled, recovered }

    private static let reminderID = "background-keep-alive-stall"
    private static let acknowledgedDeadlineKey = "backgroundKeepAlive.lastScheduledDeadline"
    private let notifications = UNUserNotificationCenter.current()
    private let audio = KeepAliveAudio()
    private let defaults = UserDefaults.standard
    private var policy = KeepAlivePolicy()
    private var hasSource: (() -> Bool)?
    private var background = false
    private var playing = false
    private var alertOwnsAudio = false
    private var interrupted = false
    private var smartStarted: TimeInterval?
    private var capReported = false
    private var audioRetryAfter: TimeInterval = 0
    private var check: Task<Void, Never>?
    private var reminderDeadline: Date?
    private var reminderOutcome: Outcome?
    private var clearedReminder = false
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: rawType, options: rawOptions)
            }
        }
    }

    public func configure(initialSample: Date?, hasSource: @escaping () -> Bool) {
        self.hasSource = hasSource
        if let initialSample { policy.accept(initialSample, now: Date()) }
        notifications.removePendingNotificationRequests(withIdentifiers: ["background-keep-alive-expired"])
        reevaluate()
    }

    public func setBackground(_ value: Bool) {
        background = value
        if !value { interrupted = false }
        reevaluate()
    }

    public func settingsChanged() { reevaluate() }

    public func noteGlucoseSample(at timestamp: Date) {
        let now = Date()
        let configuration = configuration
        let interval = configuration.stallInterval
        let wasStale = policy.isStale(now: now, interval: interval)
        guard policy.accept(timestamp, now: now) else { return }
        if !policy.isStale(now: now, interval: interval) {
            smartStarted = nil
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
        check?.cancel()
        check = nil
        let configuration = configuration
        guard configuration.mode != .off, hasSource() else {
            clearReminder()
            stopAudio(.stopped)
            return
        }

        let now = Date()
        let deadline = policy.deadline(interval: configuration.stallInterval)
        if let deadline { scheduleReminder(for: deadline, now: now, interval: configuration.stallInterval) }

        guard background, !alertOwnsAudio, !interrupted else {
            stopAudio(.stopped)
            return
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        if configuration.mode == .smart {
            guard let deadline else { return }
            if deadline > now {
                stopAudio(.stopped)
                armCheck(after: deadline.timeIntervalSince(now))
                return
            }
            if let smartStarted, uptime - smartStarted >= configuration.capInterval {
                stopAudio(.stopped, report: false)
                if !capReported {
                    capReported = true
                    record(.audio, .capped)
                }
                return
            }
        }

        guard uptime >= audioRetryAfter else {
            armCheck(after: audioRetryAfter - uptime)
            return
        }
        if !audio.isRunning {
            audio.stop()
            guard audio.start() else {
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

        if configuration.mode == .smart {
            let start = smartStarted ?? uptime
            smartStarted = start
            armCheck(after: min(60, max(1, configuration.capInterval - (uptime - start))))
        } else {
            armCheck(after: 60)
        }
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
        if let current = reminderDeadline, current == deadline || (current <= now && deadline <= now) { return }
        if reminderDeadline == nil, deadline <= now,
           defaults.object(forKey: Self.acknowledgedDeadlineKey) as? Date == deadline
        {
            reminderDeadline = deadline
            return
        }
        reminderDeadline = deadline
        clearedReminder = false

        let content = UNMutableNotificationContent()
        let minutes = Int(interval / 60)
        content.title = String(localized: "Glucose Data Interrupted", bundle: .main)
        content.body = String(localized: "No new glucose readings for \(minutes) minutes. Open Trio and check the CGM connection.", bundle: .main)
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
    }

    private func stopAudio(_ outcome: Outcome, report: Bool = true) {
        audio.stop()
        if playing, report { record(.audio, outcome) }
        playing = false
    }

    private func handleInterruption(type: UInt, options: UInt) {
        switch AVAudioSession.InterruptionType(rawValue: type) {
        case .began:
            interrupted = true
            stopAudio(.interrupted)
            reevaluate()
        case .ended:
            interrupted = !AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            reevaluate()
        default: break
        }
    }

    private func record(_ stage: Stage, _ outcome: Outcome) {
        NotificationCenter.default.post(name: .init("com.trio.diagnostics.event"), object: nil, userInfo: [
            "schema": 1, "feature": "keep_alive", "stage": stage.rawValue, "outcome": outcome.rawValue
        ])
    }
}
#endif

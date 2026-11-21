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
    public enum Status: String { case disabled, noSource, foreground, protecting, interrupted, alert, limited, failed, waiting }
    @Published public private(set) var status: Status = .foreground
    @Published public private(set) var audioSessionSeconds: TimeInterval = 0
    @Published public private(set) var audioStarts = 0
    @Published public private(set) var lastCycleDelaySeconds: TimeInterval = 0
    @Published public private(set) var missedAudioWindows = 0

    public enum SettingsKey {
        public static let mode = "backgroundKeepAlive.mode"
        public static let stallMinutes = "backgroundKeepAlive.stallMinutes"
        public static let maxSessionMinutes = "backgroundKeepAlive.maxSessionMinutes"
        public static let cycleMinutes = "backgroundKeepAlive.cycleMinutes"
        public static let audioMinutes = "backgroundKeepAlive.audioMinutes"
    }

    private enum Stage: String {
        case audio, reminder, data, source, lifecycle, recovery
        case audioMinutes = "audio_minutes", audioStarts = "audio_starts", cycleDelay = "cycle_delay_seconds"
        case missedWindows = "missed_windows"
    }
    private enum Outcome: String {
        case started, stopped, failed, interrupted, capped, scheduled, recovered, received, stored
        case background, foreground, requested, completed, timedOut = "timed_out", reset, overdue, sampled
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
    private var latestStoredSample: (() -> Date?)?
    private var sourceIdentifier: (() -> String?)?
    private var currentSourceID = UserDefaults.standard.string(forKey: "backgroundKeepAlive.sourceID")
    private var windows = PeriodicAudioWindows()
    private var periodicStartedAt: TimeInterval?
    private var refresh: RefreshHandler?
    private var privateReminderTitle: (() -> String?)?
    private var interruptionChanged: ((Date?) -> Void)?
    private var interruptionDelivered: ((Date, Date) -> Void)?
    private var activeOutage: Date?
    private var background = false
    private var playing = false
    private var alertOwnsAudio = false
    private var interruption = KeepAliveInterruptionState()
    private var audioAccountedAt: TimeInterval?
    private var periodicConfiguration: String?
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
    private struct ReminderPlan: Equatable { let deadline: Date?; let privateTitle: String?; var sourceID: String? = nil }
    private lazy var reminderWriter = LatestAsyncWriter<ReminderPlan> { [weak self] plan in await self?.applyReminder(plan) }

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

    public func configure(initialSample: Date?, hasSource: @escaping () -> Bool, refresh: RefreshHandler? = nil,
                          latestStoredSample: (() -> Date?)? = nil, privateReminderTitle: (() -> String?)? = nil,
                          interruptionChanged: ((Date?) -> Void)? = nil, sourceID: (() -> String?)? = nil,
                          interruptionDelivered: ((Date, Date) -> Void)? = nil) {
        self.hasSource = hasSource
        self.latestStoredSample = latestStoredSample
        sourceIdentifier = sourceID
        self.refresh = refresh
        self.privateReminderTitle = privateReminderTitle
        self.interruptionChanged = interruptionChanged
        self.interruptionDelivered = interruptionDelivered
        if sourceID == nil, let initialSample { policy.accept(initialSample, now: Date()) }
        notifications.removePendingNotificationRequests(withIdentifiers: ["background-keep-alive-expired"])
        reevaluate()
    }

    public func setBackground(_ value: Bool) {
        if value != background {
            accountMissedWindows(uptime: ProcessInfo.processInfo.systemUptime)
            windows = PeriodicAudioWindows()
            periodicStartedAt = value ? ProcessInfo.processInfo.systemUptime : nil
            record(.lifecycle, value ? .background : .foreground)
            policy.backgroundChanged(value, uptime: ProcessInfo.processInfo.systemUptime)
        }
        background = value
        reevaluate()
    }

    public func settingsChanged() { reevaluate() }

    public func noteSourceActivity() {
        guard hasSource?() == true else { return }
        record(.source, .received)
        reevaluate()
    }

    /// Called only after accepted CGM storage; the source epoch is captured before the fetch.
    nonisolated public static func reportStoredSample(at timestamp: Date, sourceID: String) {
        AcceptedCGMSnapshotStore.record(timestamp, sourceID: sourceID)
        Task { @MainActor in shared.noteGlucoseSample(at: timestamp, sourceID: sourceID) }
    }

    public func noteGlucoseSample(at timestamp: Date, sourceID: String? = nil) {
        if let expected = sourceIdentifier?(), sourceID != expected { return }
        let now = Date()
        let configuration = configuration
        let interval = configuration.stallInterval
        let wasStale = policy.isStale(now: now, interval: interval)
        guard policy.accept(timestamp, now: now) else { return }
        record(.data, .stored)
        if !policy.isStale(now: now, interval: interval) {
            if wasStale, configuration.mode != .off, hasSource?() == true {
                record(.data, .recovered)
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
            maxSessionMinutes: defaults.integer(forKey: SettingsKey.maxSessionMinutes),
            cycleMinutes: defaults.object(forKey: SettingsKey.cycleMinutes) as? Int ?? 30,
            audioMinutes: defaults.object(forKey: SettingsKey.audioMinutes) as? Int ?? 5
        )
    }

    private func reevaluate() {
        guard let hasSource else { return }
        interruption.wake(otherAudio: AVAudioSession.sharedInstance().isOtherAudioPlaying)
        check?.cancel()
        check = nil
        let configuration = configuration
        synchronizeSource(now: Date())
        guard configuration.mode != .off, hasSource() else {
            status = configuration.mode == .off ? .disabled : .noSource
            policy.endMonitoring()
            periodicConfiguration = nil
            clearReminder()
            stopAudio(.stopped)
            finishRefresh(.stopped)
            endOutage()
            return
        }

        let now = Date()
        // A storage callback can still be queued on the main actor. Read the accepted store before scheduling.
        if let accepted = acceptedSample(now: now) { policy.accept(accepted, now: now) }
        policy.beginMonitoring(at: now)
        let oldAcknowledgement = defaults.object(forKey: Self.acknowledgedDeadlineKey) as? Date
        if KeepAliveReminderPolicy.acknowledgementAfterSample(oldAcknowledgement, sample: policy.latestSample, now: now) == nil {
            defaults.removeObject(forKey: Self.acknowledgedDeadlineKey)
        }
        let deadline = policy.deadline(interval: configuration.stallInterval)
        if let deadline { scheduleReminder(for: deadline, now: now, interval: configuration.stallInterval) }

        let uptime = ProcessInfo.processInfo.systemUptime
        accountMissedWindows(uptime: uptime)
        accountAudio(until: uptime)
        let periodicKey = "\(configuration.mode.rawValue)|\(configuration.cycleInterval)|\(configuration.audioInterval)"
        if periodicConfiguration != periodicKey {
            periodicConfiguration = periodicKey
            policy.backgroundChanged(background, uptime: uptime)
            windows = PeriodicAudioWindows()
            periodicStartedAt = background ? uptime : nil
        }
        let stale = policy.isStale(now: now, interval: configuration.stallInterval)
        if stale, activeOutage == nil, let deadline {
            activeOutage = deadline
            interruptionChanged?(deadline)
        } else if !stale { endOutage(); interruptionChanged?(nil) }
        if stale { record(.data, .overdue); requestRefresh(now: now) }

        guard policy.wantsAudio(configuration: configuration, now: now, background: background,
                                blocked: alertOwnsAudio || interruption.blocked, uptime: uptime) else {
            status = !background ? .foreground : (alertOwnsAudio ? .alert : (interruption.blocked ? .interrupted : .waiting))
            stopAudio(.stopped)
            // Timers are only opportunistic; Bluetooth wakes and foreground events also reevaluate.
            if background { armCheck(after: nextCheckDelay(configuration: configuration, now: now, uptime: uptime)) }
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
                audioAccountedAt = nil
                audioRetryAfter = uptime + 60
                armCheck(after: 60)
                return
            }
            playing = true
            audioStarts += 1
            audioAccountedAt = uptime
            record(.audioStarts, .sampled, count: audioStarts, force: true)
            if configuration.mode == .periodic {
                accountMissedWindows(uptime: uptime, started: true)
                lastCycleDelaySeconds = policy.periodicPhase(configuration: configuration, now: now, uptime: uptime)
                record(.cycleDelay, .sampled, count: Int(lastCycleDelaySeconds), force: true)
            }
            audioRetryAfter = 0
            record(.audio, .started)
        }
        if configuration.mode == .periodic { accountMissedWindows(uptime: uptime, started: audio.isRunning) }
        status = .protecting

        armCheck(after: nextCheckDelay(configuration: configuration, now: now, uptime: uptime))
    }

    private func nextCheckDelay(configuration: KeepAlivePolicy.Configuration, now: Date, uptime: TimeInterval) -> TimeInterval {
        if configuration.mode == .periodic {
            let phase = policy.periodicPhase(configuration: configuration, now: now, uptime: uptime)
            let boundary = phase < configuration.audioInterval ? configuration.audioInterval : configuration.cycleInterval
            return min(60, max(1, boundary - phase))
        }
        if let deadline = policy.deadline(interval: configuration.stallInterval), deadline > now {
            return min(60, max(1, deadline.timeIntervalSince(now)))
        }
        return 60
    }

    private func accountAudio(until uptime: TimeInterval) {
        guard let previous = audioAccountedAt else { return }
        audioSessionSeconds += max(0, uptime - previous)
        audioAccountedAt = uptime
        record(.audioMinutes, .sampled, count: Int(audioSessionSeconds / 60))
    }

    private func synchronizeSource(now: Date) {
        guard let sourceIdentifier else { return }
        let selected = sourceIdentifier()
        if currentSourceID != selected || policy.latestSample.map({ $0 > now }) == true {
            currentSourceID = selected
            policy.endMonitoring()
            clearReminder()
            endOutage()
            defaults.set(selected, forKey: "backgroundKeepAlive.sourceID")
        }
    }

    private func acceptedSample(now: Date) -> Date? {
        guard let sourceIdentifier else { return latestStoredSample?() }
        var state = AcceptedCGMSnapshotStore.load()
        state.select(sourceIdentifier())
        return state.latest(now: now)
    }

    private func accountMissedWindows(uptime: TimeInterval, started: Bool = false) {
        guard background, configuration.mode == .periodic, let start = periodicStartedAt else { return }
        let key = "\(configuration.mode.rawValue)|\(configuration.cycleInterval)|\(configuration.audioInterval)"
        guard periodicConfiguration == key else { return }
        let skipped = windows.observe(elapsed: uptime - start, cycle: configuration.cycleInterval,
                                      on: configuration.audioInterval, started: started)
        if skipped > 0 {
            missedAudioWindows += skipped
            record(.missedWindows, .sampled, count: missedAudioWindows, force: true)
        }
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
        if privacyChanged { reminderDeadline = nil }
        reminderIsPrivate = isPrivate
        if let current = reminderDeadline, current == deadline || (current <= now && deadline <= now) { return }
        if !KeepAliveReminderPolicy.shouldNotify(deadline: deadline, now: now,
            acknowledged: defaults.object(forKey: Self.acknowledgedDeadlineKey) as? Date, privacyChanged: privacyChanged) {
            reminderDeadline = deadline
            if privacyChanged { reminderWriter.set(.init(deadline: nil, privateTitle: privateTitle)) }
            return
        }
        reminderDeadline = deadline
        clearedReminder = false
        reminderWriter.set(.init(deadline: deadline, privateTitle: privateTitle, sourceID: currentSourceID), force: reminderOutcome == .failed)
    }

    private func applyReminder(_ plan: ReminderPlan) async {
        // Even a late add followed by disable/privacy-change must finish with the newest remove/replace.
        await ReminderDeliveryArchive.captureBeforeRemoval(capture: {
            await self.notifications.deliveredNotifications().filter { $0.request.identifier == Self.reminderID }.map {
                let deadline = ($0.request.content.userInfo["deadline"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? $0.date
                self.interruptionDelivered?(deadline, $0.date)
                return deadline
            }
        }, record: { self.interruptionChanged?($0) }, remove: {
            self.notifications.removeDeliveredNotifications(withIdentifiers: [Self.reminderID])
        })
        if !policy.isStale(now: Date(), interval: 360) { interruptionChanged?(nil) }
        guard let deadline = plan.deadline else {
            notifications.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
            return
        }
        if let latest = acceptedSample(now: Date()), policy.accept(latest, now: Date()) {
            reevaluate()
            // Newer backfill that is still stale belongs to the existing due episode.
            // Keep its original write instead of suppressing both the old and replacement plans.
            guard deadline <= Date(), policy.isStale(now: Date(), interval: 360) else { return }
        }
        guard hasSource?() == true, configuration.mode != .off,
              plan.sourceID == currentSourceID,
              sourceIdentifier == nil || plan.sourceID == sourceIdentifier?(),
              plan.privateTitle == privateReminderTitle?(),
              let current = policy.deadline(interval: 360),
              KeepAliveReminderPolicy.canApply(planned: deadline, current: current, now: Date()) else { return }

        let content = UNMutableNotificationContent()
        let minutes = 6
        content.title = String(localized: "Glucose Data Interrupted", bundle: .main)
        content.body = String(localized: "No new glucose readings for \(minutes) minutes. Open Trio and check the CGM connection.", bundle: .main)
        if let privateTitle = plan.privateTitle { content.title = privateTitle; content.body = "" }
        content.sound = .default
        content.userInfo = ["deadline": deadline.timeIntervalSince1970]
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: trigger)
        do {
            try await notifications.add(request)
            guard reminderDeadline == deadline else { return }
            defaults.set(deadline, forKey: Self.acknowledgedDeadlineKey)
            if reminderOutcome != .scheduled { reminderOutcome = .scheduled; record(.reminder, .scheduled) }
        } catch {
            guard reminderDeadline == deadline else { return }
            reminderDeadline = nil
            reminderOutcome = .failed
            record(.reminder, .failed)
        }
    }

    private func clearReminder() {
        guard !clearedReminder else { return }
        reminderDeadline = nil
        reminderOutcome = nil
        clearedReminder = true
        defaults.removeObject(forKey: Self.acknowledgedDeadlineKey)
        reminderWriter.set(.init(deadline: nil, privateTitle: nil))
    }

    private func endOutage() {
        guard activeOutage != nil else { return }
        activeOutage = nil
        interruptionChanged?(nil)
    }

    private func stopAudio(_ outcome: Outcome, report: Bool = true) {
        accountAudio(until: ProcessInfo.processInfo.systemUptime)
        audioAccountedAt = nil
        audio.stop()
        if playing { record(.audioMinutes, .sampled, count: Int(audioSessionSeconds / 60), force: true) }
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

    private func record(_ stage: Stage, _ outcome: Outcome, count: Int? = nil, force: Bool = false) {
        let now = Date()
        if !force, let (previous, date) = recentEvents[stage], previous == outcome, now.timeIntervalSince(date) < 300 { return }
        recentEvents[stage] = (outcome, now)
        var info: [String: Any] = [
            "schema": 1, "feature": "keep_alive", "stage": stage.rawValue, "outcome": outcome.rawValue
        ]
        if let count { info["count"] = min(9_999, max(0, count)) }
        NotificationCenter.default.post(name: .init("com.trio.diagnostics.event"), object: nil, userInfo: info)
    }
}
#endif

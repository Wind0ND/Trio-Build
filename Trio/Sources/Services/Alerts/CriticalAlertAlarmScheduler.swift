import CryptoKit
import Foundation
import LoopKit
import PrivacyKit

#if canImport(AlarmKit)
    import ActivityKit
    import AlarmKit
    import AppIntents
    import struct SwiftUI.Color // Color only; `import SwiftUI` makes `Alert` ambiguous with LoopKit.Alert
#endif

/// On iOS 26+ this schedules an AlarmKit alarm as the audible critical-alert
/// channel instead of the AVAudioSession + volume-booster + vibration hack in
/// `CriticalAlertAudioPlayer`. AlarmKit breaks through the silent switch,
/// Focus and Do Not Disturb with a system-rendered alarm, and — unlike the
/// in-process player — still fires when iOS has suspended Trio.
///
/// Requires the user to grant AlarmKit authorization. When AlarmKit is
/// unavailable (iOS < 26) or unauthorized, callers fall back to
/// `CriticalAlertAudioPlayer`.
///
/// Ported from Loop's `CriticalAlertAlarmScheduler`.
@MainActor
final class CriticalAlertAlarmScheduler {
    nonisolated static func isProtectedShortTemp(_ identifier: Alert.Identifier) -> Bool {
        identifier.managerIdentifier == "Medtrum" &&
            identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.short-temp-cancel")
    }

    func containsShortTempAlarm(_ identifier: Alert.Identifier) -> Bool {
        guard #available(iOS 26, *), isAuthorizedAndAvailable else { return false }
        #if canImport(AlarmKit)
            return (try? AlarmManager.shared.alarms.contains { $0.id == Self.alarmID(for: identifier) }) ?? false
        #else
            return false
        #endif
    }

    /// Unlike scheduleAlarm's synchronous acceptance, this returns only after the OS accepted the alarm.
    func prearmShortTemp(_ alert: Alert, at deadline: Date) async -> Bool {
        guard #available(iOS 26, *), isAuthorizedAndAvailable, deadline > Date() else { return false }
        #if canImport(AlarmKit)
            let stopButton = AlarmButton(text: LocalizedStringResource(stringLiteral: String(localized: "Stop")),
                textColor: .white, systemImageName: "stop.circle")
            let presentation = AlarmPresentation(alert: AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: TrioPrivacyAlert.content(alert.backgroundContent, for: alert)?.title ?? alert.backgroundContent.title),
                stopButton: stopButton))
            let attributes = AlarmAttributes<EmptyAlarmMetadata>(presentation: presentation, tintColor: .red)
            let config = AlarmManager.AlarmConfiguration<EmptyAlarmMetadata>.alarm(schedule: .fixed(deadline),
                attributes: attributes, stopIntent: StopCriticalAlertIntent(identifier: alert.identifier),
                sound: .named(alert.sound?.filename ?? "honk.caf"))
            do {
                _ = try await AlarmManager.shared.schedule(id: Self.alarmID(for: alert.identifier), configuration: config)
                DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "scheduled")
                return true
            } catch {
                DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "failed")
                return false
            }
        #else
            return false
        #endif
    }
    private var pendingSchedules: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var burstStops: [UUID: Task<Void, Never>] = [:]
    /// The AlarmKit alarm ID for an alert, derived from the alert identifier so
    /// a relaunched app can still stop an alarm scheduled by an earlier process.
    nonisolated static func alarmID(for identifier: Alert.Identifier) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(identifier.value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// True only if AlarmKit is available (iOS 26+) AND the user authorized it.
    /// When false, callers should use the `CriticalAlertAudioPlayer` fallback.
    var isAuthorizedAndAvailable: Bool {
        guard #available(iOS 26, *) else { return false }
        #if canImport(AlarmKit)
            return AlarmManager.shared.authorizationState == .authorized
        #else
            return false
        #endif
    }

    /// Request AlarmKit authorization if it hasn't been decided yet. No-op
    /// below iOS 26 or once already granted/denied.
    static func requestAuthorization() async {
        guard #available(iOS 26, *) else { return }
        #if canImport(AlarmKit)
            guard AlarmManager.shared.authorizationState == .notDetermined else { return }
            do {
                _ = try await AlarmManager.shared.requestAuthorization()
            } catch let authorizationError {
                warning(.alerts, "AlarmKit authorization request failed", error: authorizationError)
            }
        #endif
    }

    /// AlarmKit fixed alarms ring at a future wall-clock moment; a now/past
    /// date schedules silently and never fires, so nudge it a couple seconds ahead.
    private static let immediateFireDelay: TimeInterval = 2

    /// Schedule the alert at its fixed deadline, or immediately if none is supplied.
    /// Returns true if AlarmKit will handle it, so the caller skips the audio
    /// fallback. `onScheduleFailure` runs if the async schedule throws, so the
    /// caller can still play the fallback rather than leaving the alert silent.
    @discardableResult func scheduleAlarm(for alert: Alert, at deadline: Date? = nil,
                                         onScheduled: @escaping () -> Void = {},
                                         onScheduleFailure: @escaping () -> Void) -> Bool {
        guard #available(iOS 26, *), isAuthorizedAndAvailable else { return false }
        #if canImport(AlarmKit)
            let id = Self.alarmID(for: alert.identifier)
            let previous = pendingSchedules[id]?.task
            cancelAlarm(for: alert.identifier)

            let stopButton = AlarmButton(
                text: LocalizedStringResource(stringLiteral: String(localized: "Stop")),
                textColor: .white,
                systemImageName: "stop.circle"
            )
            let presentation = AlarmPresentation(
                alert: AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: TrioPrivacyAlert.content(alert.backgroundContent, for: alert)?.title ?? alert.backgroundContent.title),
                    stopButton: stopButton
                )
            )
            let attributes = AlarmAttributes<EmptyAlarmMetadata>(presentation: presentation, tintColor: TrioPrivacyAlert.kind(alert)?.color.swiftUIColor ?? .red)

            // Alert-only (no countdownDuration) so no Widget Extension / Live
            // Activity is required. `AlertSound.named` resolves the same way
            // `UNNotificationSoundName` does — main bundle root or
            // Library/Sounds — which is where Trio's tones now live.
            let sound: AlertConfiguration.AlertSound = alert.sound?.filename
                .map { .named($0) } ?? .default
            let fireDate = deadline ?? Date().addingTimeInterval(Self.immediateFireDelay)
            let configuration = AlarmManager.AlarmConfiguration<EmptyAlarmMetadata>.alarm(
                schedule: .fixed(fireDate),
                attributes: attributes,
                stopIntent: StopCriticalAlertIntent(identifier: alert.identifier),
                sound: sound
            )

            let identifier = alert.identifier
            // AlarmKit rings until stopped, so end it after the same burst the
            // in-app player would play. Best-effort: if iOS suspends Trio, it
            // stops on Trio's next wake (the next CGM reading at the latest).
            let burst = alert.sound?.filename
                .map(CriticalAlertAudioPlayer.burstDuration(forSoundNamed:)) ?? CriticalAlertAudioPlayer.minBurstDuration
            let token = UUID()
            let operation = Task {
                // An earlier schedule can finish after cancellation. Wait for
                // its cleanup before reusing this alert's stable system ID.
                await previous?.value
                defer { if pendingSchedules[id]?.token == token { pendingSchedules[id] = nil } }
                guard !Task.isCancelled else { return }
                guard fireDate > Date() else { onScheduleFailure(); return }
                do {
                    _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
                    guard !Task.isCancelled else {
                        cancelSystemAlarm(for: identifier)
                        return
                    }
                    DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "scheduled")
                    info(.alerts, "AlarmKit alarm scheduled for \(identifier.value)")
                    onScheduled()
                    if Self.isProtectedShortTemp(identifier) { return }
                    burstStops[id] = Task {
                        do { try await Task.sleep(for: .seconds(max(0, fireDate.timeIntervalSinceNow + burst))) }
                        catch { return }
                        stopIfAlerting(id: id, identifier: identifier)
                        burstStops[id] = nil
                    }
                } catch let scheduleError {
                    guard !Task.isCancelled else { return }
                    DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "failed")
                    warning(
                        .alerts,
                        "Scheduling AlarmKit alarm for \(identifier.value) failed, falling back to audio",
                        error: scheduleError
                    )
                    onScheduleFailure()
                }
            }
            pendingSchedules[id] = (token, operation)
            return true
        #else
            return false
        #endif
    }

    @available(iOS 26, *) private func stopIfAlerting(id: UUID, identifier: Alert.Identifier) {
        #if canImport(AlarmKit)
            guard let alarm = try? AlarmManager.shared.alarms.first(where: { $0.id == id }),
                  alarm.state == .alerting
            else { return }
            do {
                try AlarmManager.shared.stop(id: id)
                DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "stopped")
            } catch {
                DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "failed")
            }
            debug(.alerts, "AlarmKit alarm for \(identifier.value) stopped after its burst")
        #endif
    }

    /// Cancel/stop the AlarmKit alarm scheduled for the given alert, if any.
    @discardableResult func cancelAlarm(for identifier: Alert.Identifier) -> Bool {
        let id = Self.alarmID(for: identifier)
        pendingSchedules[id]?.task.cancel()
        burstStops.removeValue(forKey: id)?.cancel()
        return cancelSystemAlarm(for: identifier)
    }

    @discardableResult private func cancelSystemAlarm(for identifier: Alert.Identifier) -> Bool {
        guard #available(iOS 26, *) else { return true }
        #if canImport(AlarmKit)
            let id = Self.alarmID(for: identifier)
            do {
                guard let alarm = try AlarmManager.shared.alarms.first(where: { $0.id == id }) else { return true }
                // stop() ends a ringing alarm; cancel() removes a scheduled one
                if alarm.state == .alerting {
                    try AlarmManager.shared.stop(id: id)
                } else {
                    try AlarmManager.shared.cancel(id: id)
                }
                debug(.alerts, "AlarmKit alarm cancelled for \(identifier.value)")
                DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "cancelled")
                return true
            } catch let cancelError {
                DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "failed")
                warning(.alerts, "Cancelling AlarmKit alarm for \(identifier.value) failed", error: cancelError)
                return false
            }
        #else
            return true
        #endif
    }
}

/// Hands the AlarmKit Stop button's tap back to the alert manager so the
/// corresponding Trio alert is acknowledged, not just silenced. The intent is
/// reconstructed by the system and has no reference to the live manager, so it
/// routes through this shared bridge. Taps that arrive before the manager
/// registers (e.g. the app was relaunched to run the intent) are queued and
/// flushed once it does.
@MainActor final class CriticalAlertAcknowledgementBridge {
    static let shared = CriticalAlertAcknowledgementBridge()
    private init() {}

    private var handler: ((Alert.Identifier) async -> Void)?
    private var pending: [Alert.Identifier] = []

    func setHandler(_ handler: @escaping (Alert.Identifier) async -> Void) {
        self.handler = handler
        guard !pending.isEmpty else { return }
        let queued = pending
        pending = []
        Task { for identifier in queued { await handler(identifier) } }
    }

    func acknowledge(_ identifier: Alert.Identifier) async {
        if let handler {
            await handler(identifier)
        } else {
            pending.append(identifier)
        }
    }
}

#if canImport(AlarmKit)
    /// Trio critical-alert alarms are alert-only (no countdown / custom Live
    /// Activity), so this carries nothing.
    @available(iOS 26, *) struct EmptyAlarmMetadata: AlarmMetadata {
        init() {}
    }

    /// Runs in the app process when the user taps Stop on an AlarmKit critical
    /// alarm. Carries the alert identifier as parameters so the system can
    /// reconstruct it.
    @available(iOS 26, *) struct StopCriticalAlertIntent: LiveActivityIntent {
        static var title: LocalizedStringResource = "Stop Trio Alarm"
        static var isDiscoverable: Bool = false

        @Parameter(title: "Manager Identifier") var managerIdentifier: String
        @Parameter(title: "Alert Identifier") var alertIdentifier: String

        init() {}

        init(identifier: Alert.Identifier) {
            managerIdentifier = identifier.managerIdentifier
            alertIdentifier = identifier.alertIdentifier
        }

        func perform() async throws -> some IntentResult {
            let identifier = Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: alertIdentifier)
            if CriticalAlertAlarmScheduler.isProtectedShortTemp(identifier),
               await HiroBasalPulseAlarms.shared.stopped(identifier) {
                return .result()
            }
            await CriticalAlertAcknowledgementBridge.shared.acknowledge(
                identifier
            )
            return .result()
        }
    }
#endif

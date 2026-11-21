import AppIntents
import Foundation
import LoopKit
import PrivacyAppKit
import PrivacyKit
import UserNotifications

enum TrioPrivacyAlert {
    static func inAppContent(_ original: LoopKit.Alert.Content?, for alert: LoopKit.Alert, isActive: Bool,
                             isLocked: Bool, enabled: Bool) -> LoopKit.Alert.Content? {
        !isActive || isLocked ? content(original, for: alert, enabled: enabled) : original
    }
    static func kind(_ alert: LoopKit.Alert, enabled: Bool = PrivacyPreference.alertsEnabled) -> PrivacyGlucoseAlarm? {
        guard enabled else { return nil }
        return PrivacyGlucoseAlarm(identifier: alert.identifier.alertIdentifier)
    }

    static func content(
        _ original: LoopKit.Alert.Content?, for alert: LoopKit.Alert,
        enabled: Bool = PrivacyPreference.alertsEnabled
    ) -> LoopKit.Alert.Content? {
        guard let original, kind(alert, enabled: enabled) != nil else { return original }
        return LoopKit.Alert.Content(title: PrivacyText.attention, body: "", actions: original.actions)
    }
}

/// Serialize privacy replacement with the existing notification schedule/cancel paths.
/// An enumeration taken before a cancellation or new alert must never recreate an old alert.
enum PrivacyNotificationLifecycle {
    private static let lock = NSRecursiveLock()
    private static var generations: [String: UInt64] = [:]
    private static var cancelled = Set<String>()

    static var revision: [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return generations
    }

    static func schedule(_ request: UNNotificationRequest, center: UNUserNotificationCenter, completion: @escaping (Error?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        generations[request.identifier, default: 0] &+= 1
        cancelled.remove(request.identifier)
        var outgoing = request
        if PrivacyPreference.alertsEnabled,
           let slug = request.content.userInfo[AlertUserInfoKey.alertIdentifier.rawValue] as? String,
           PrivacyGlucoseAlarm(identifier: slug) != nil,
           let content = request.content.mutableCopy() as? UNMutableNotificationContent
        {
            content.title = PrivacyText.attention
            content.subtitle = ""
            content.body = ""
            outgoing = UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger)
        }
        center.add(outgoing) { error in
            completion(error)
            // A privacy change can happen while notification delivery is in flight.
            if error == nil, PrivacyPreference.alertsEnabled { TrioPrivacyCoordinator.reconcile() }
        }
    }

    static func cancel(_ identifiers: [String], center: UNUserNotificationCenter) {
        lock.lock()
        defer { lock.unlock() }
        for identifier in identifiers { generations[identifier, default: 0] &+= 1 }
        cancelled.formUnion(identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        let captured = generations
        center.getDeliveredNotifications { notes in
            notes.filter { identifiers.contains($0.request.identifier) }.forEach {
                HiroAlertJournal.shared.observedNotification($0)
            }
            lock.lock()
            defer { lock.unlock() }
            let unchanged = identifiers.filter { captured[$0] == generations[$0] && cancelled.contains($0) }
            center.removeDeliveredNotifications(withIdentifiers: unchanged)
        }
    }

    static func invalidate(_ identifiers: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for identifier in identifiers { generations[identifier, default: 0] &+= 1 }
        cancelled.formUnion(identifiers)
    }

    static func replace(_ request: UNNotificationRequest, revision: UInt64, center: UNUserNotificationCenter) {
        lock.lock()
        defer { lock.unlock() }
        guard generations[request.identifier, default: 0] == revision, !cancelled.contains(request.identifier), PrivacyPreference.alertsEnabled else { return }
        center.add(request) { _ in
            lock.lock()
            defer { lock.unlock() }
            if cancelled.contains(request.identifier) {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            }
        }
    }
}

/// Replaces already-delivered glucose text silently when privacy is enabled.
/// All original alert identifiers and persisted clinical content remain intact.
final class TrioPrivacyCoordinator {
    static let shared = TrioPrivacyCoordinator()
    private var observer: NSObjectProtocol?

    private init() {
        observer = Foundation.NotificationCenter.default.addObserver(
            forName: PrivacyPreference.changed, object: nil, queue: .main
        ) { _ in
            Self.reconcile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.reconcile() }
        }
    }

    static func reconcile() {
            guard PrivacyPreference.alertsEnabled else { return }
            let center = UNUserNotificationCenter.current()
            let revision = PrivacyNotificationLifecycle.revision
            center.getPendingNotificationRequests { requests in
                for request in requests {
                    guard let slug = request.content.userInfo[AlertUserInfoKey.alertIdentifier.rawValue] as? String,
                          PrivacyGlucoseAlarm(identifier: slug) != nil,
                          request.trigger != nil,
                          request.content.title != PrivacyText.attention || !request.content.body.isEmpty || !request.content.subtitle.isEmpty,
                          let content = request.content.mutableCopy() as? UNMutableNotificationContent
                    else { continue }
                    content.title = PrivacyText.attention
                    content.subtitle = ""
                    content.body = ""
                    var trigger = request.trigger
                    // Retain the remaining delay instead of starting a delayed alert's full interval again.
                    if let interval = trigger as? UNTimeIntervalNotificationTrigger, !interval.repeats,
                       let date = interval.nextTriggerDate()
                    {
                        trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
                    }
                    PrivacyNotificationLifecycle.replace(
                        UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger),
                        revision: revision[request.identifier, default: 0], center: center
                    )
                }
            }
            center.getDeliveredNotifications { notifications in
                for notification in notifications {
                    let request = notification.request
                    guard let slug = request.content.userInfo[AlertUserInfoKey.alertIdentifier.rawValue] as? String,
                          PrivacyGlucoseAlarm(identifier: slug) != nil,
                          request.content.title != PrivacyText.attention || !request.content.body.isEmpty,
                          let content = request.content.mutableCopy() as? UNMutableNotificationContent
                    else { continue }
                    content.title = PrivacyText.attention
                    content.subtitle = ""
                    content.body = ""
                    content.sound = nil
                    PrivacyNotificationLifecycle.replace(
                        UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil),
                        revision: revision[request.identifier, default: 0], center: center
                    )
                }
            }
    }
}

struct EnablePrivateActivityIntent: LiveActivityIntent {
    static var title = LocalizedStringResource("Enable private activity")
    static var description = IntentDescription("Show a discreet waveform instead of glucose numbers.")

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: PrivacyPreference.displayKey)
        PrivacyPreference.record(stage: "settings", outcome: "changed")
        PrivacyPreference.notifyChanged()
        return .result()
    }
}

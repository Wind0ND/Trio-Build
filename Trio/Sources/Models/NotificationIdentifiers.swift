import Foundation
import UserNotifications

enum AlertUserInfoKey: String {
    case managerIdentifier = "trio.alert.managerIdentifier"
    case alertIdentifier = "trio.alert.alertIdentifier"
    case occurrence = "hiro.alert.occurrence"
}

enum NotificationCategoryIdentifier: String {
    case trioAlert = "Trio.alert"
    case quickSnoozeOnly = "Trio.alert.quickSnoozeOnly"

    static func alert(isCritical: Bool, slug: String) -> Self {
        isCritical || slug.split(separator: ".").prefix(2).elementsEqual(["glucose", "urgentLow"])
            ? .quickSnoozeOnly : .trioAlert
    }

    func limitSnooze(_ duration: TimeInterval) -> TimeInterval {
        self == .quickSnoozeOnly ? min(duration, NotificationResponseAction.snooze15.duration) : duration
    }
}

enum NotificationResponseAction: String, CaseIterable, Codable {
    case snooze15 = "Trio.snooze15"
    case snooze1hr = "Trio.snooze1hr"
    case snooze3hr = "Trio.snooze3hr"
    case snooze6hr = "Trio.snooze6hr"

    var duration: TimeInterval {
        TimeInterval(minutes) * 60
    }

    var minutes: Int {
        switch self {
        case .snooze15:
            return 15
        case .snooze1hr:
            return 60
        case .snooze3hr:
            return 180
        case .snooze6hr:
            return 360
        }
    }

    var localizedTitle: String {
        switch self {
        case .snooze15:
            return String(localized: "Snooze 15 min", comment: "Snooze glucose alerts for 15 minutes")
        case .snooze1hr:
            return String(localized: "Snooze 1 hr", comment: "Snooze glucose alerts for 1 hour")
        case .snooze3hr:
            return String(localized: "Snooze 3 hrs", comment: "Snooze glucose alerts for 3 hours")
        case .snooze6hr:
            return String(localized: "Snooze 6 hrs", comment: "Snooze glucose alerts for 6 hours")
        }
    }
}

/// Phone and mirrored watch actions identify the original occurrence and tap
/// time, including when the watch delivers its message after reconnecting.
struct AlertNotificationSnooze: Codable {
    static let messageKey = "watchAlertSnooze"
    let managerIdentifier: String
    let alertIdentifier: String
    private let occurrence: UUID
    private let action: NotificationResponseAction
    private let requestedAt: Date

    init?(content: UNNotificationContent, action: NotificationResponseAction, at date: Date) {
        guard let manager = content.userInfo[AlertUserInfoKey.managerIdentifier.rawValue] as? String,
              let slug = content.userInfo[AlertUserInfoKey.alertIdentifier.rawValue] as? String,
              let raw = content.userInfo[AlertUserInfoKey.occurrence.rawValue] as? String,
              let id = UUID(uuidString: raw) else { return nil }
        managerIdentifier = manager
        alertIdentifier = slug
        occurrence = id
        let category = NotificationCategoryIdentifier.alert(isCritical: content.interruptionLevel == .critical, slug: slug)
        self.action = category == .quickSnoozeOnly ? .snooze15 : action
        requestedAt = date
    }

    func until(currentOccurrence: UUID?, isCritical: Bool, now: Date) -> Date? {
        guard currentOccurrence == occurrence, requestedAt.timeIntervalSince(now) <= 30 else { return nil }
        let category = NotificationCategoryIdentifier.alert(isCritical: isCritical, slug: alertIdentifier)
        let deadline = min(requestedAt, now).addingTimeInterval(category.limitSnooze(action.duration))
        return deadline > now ? deadline : nil
    }
}

// MARK: - NotificationCategoryFactory

enum NotificationCategoryFactory {
    static func makeCategory(_ category: NotificationCategoryIdentifier) -> UNNotificationCategory {
        let actions: [NotificationResponseAction] = category == .quickSnoozeOnly ? [.snooze15] : NotificationResponseAction.allCases
        let snoozeActions = actions.map { action in
            UNNotificationAction(
                identifier: action.rawValue,
                title: action.localizedTitle,
                options: []
            )
        }

        // `.customDismissAction` — otherwise iOS swallows swipes silently and
        // the in-app banner outlives the notification.
        return UNNotificationCategory(
            identifier: category.rawValue,
            actions: snoozeActions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}

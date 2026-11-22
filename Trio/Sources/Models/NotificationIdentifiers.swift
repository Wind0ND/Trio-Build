import Foundation
import UserNotifications

enum AlertUserInfoKey: String {
    case managerIdentifier = "trio.alert.managerIdentifier"
    case alertIdentifier = "trio.alert.alertIdentifier"
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

enum NotificationResponseAction: String, CaseIterable {
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

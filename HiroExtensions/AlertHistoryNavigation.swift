import Foundation
import UserNotifications

/// Retains a notification destination until the main UI has installed its router.
@MainActor final class HiroAlertHistoryNavigation {
    static let shared = HiroAlertHistoryNavigation()

    static func shouldOpenHistory(actionIdentifier: String, requestIdentifier: String,
                                  userInfo: [AnyHashable: Any]) -> Bool {
        false
    }

    func request() {}
    func attach(owner: UUID, handler: @escaping () -> Void) {}
    func detach(owner: UUID) {}
}

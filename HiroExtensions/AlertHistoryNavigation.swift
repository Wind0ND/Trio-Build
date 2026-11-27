import Foundation
import UserNotifications

/// Retains a notification destination until the main UI has installed its router.
@MainActor final class HiroAlertHistoryNavigation {
    static let shared = HiroAlertHistoryNavigation()
    private var pending = false
    private var owner: UUID?
    private var handler: (() -> Void)?
    private var flushScheduled = false

    static func shouldOpenHistory(actionIdentifier: String, requestIdentifier: String,
                                  userInfo: [AnyHashable: Any]) -> Bool {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return false }
        if requestIdentifier == "background-keep-alive-stall" { return true }
        if let raw = userInfo[AlertUserInfoKey.occurrence.rawValue] as? String,
           UUID(uuidString: raw) != nil { return true }
        guard let manager = userInfo[AlertUserInfoKey.managerIdentifier.rawValue] as? String,
              let alert = userInfo[AlertUserInfoKey.alertIdentifier.rawValue] as? String else { return false }
        return !manager.isEmpty && !alert.isEmpty
    }

    func request() {
        pending = true
        scheduleFlush()
    }

    func attach(owner: UUID, handler: @escaping () -> Void) {
        self.owner = owner
        self.handler = handler
        scheduleFlush()
    }

    func detach(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        handler = nil
    }

    private func scheduleFlush() {
        guard pending, handler != nil, !flushScheduled else { return }
        flushScheduled = true
        // Main.StateModel installs asynchronous router subscriptions during
        // configureView. Let their initial nil values settle before routing.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.pending, self.owner != nil, let handler = self.handler else { return }
            self.pending = false
            handler()
        }
    }
}

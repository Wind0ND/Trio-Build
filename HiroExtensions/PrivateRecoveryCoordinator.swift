import Foundation
import PrivacyKit
import Swinject
import UIKit

/// Explicit user recovery works independently of the automatic audio preference and viewing lock.
@MainActor enum HiroPrivateRecovery {
    static func configure(resolver: Resolver) {
        PrivateRecoveryBridge.shared.configure { request in
            guard let manager = resolver.resolve(FetchGlucoseManager.self),
                  manager.cgmGlucoseSourceType != .none, manager.cgmGlucoseSourceType != .simulator,
                  request.isCurrent() else { request.complete(false); return }
            let permit = Permit(sourceRevision: manager.recoverySourceRevision, expiresAt: request.expiresAtUptime)
            var lease: UIBackgroundTaskIdentifier = .invalid
            @MainActor func finish(_ success: Bool) {
                permit.cancel()
                if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
                if request.isCurrent() {
                    record(success ? "completed" : "failed")
                    request.complete(success)
                }
            }
            lease = UIApplication.shared.beginBackgroundTask(withName: "Refresh activity") {
                permit.cancel()
                Task { @MainActor in finish(false) }
            }
            record("requested")
            // A separate deadline also invalidates storage authorization if the callback is late.
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(permit.remaining)) } catch { return }
                finish(false)
            }
            manager.requestRecovery(isAuthorized: {
                permit.isValid && manager.recoverySourceRevision == permit.sourceRevision
            }) { success in
                Task { @MainActor in
                    guard request.isCurrent(), permit.isValid else { timeout.cancel(); finish(false); return }
                    guard manager.recoverySourceRevision == permit.sourceRevision else {
                        timeout.cancel(); finish(false); return
                    }
                    await resolver.resolve(LiveActivityManager.self)?.refreshCurrentContent(isAuthorized: {
                        request.isCurrent() && permit.isValid && manager.recoverySourceRevision == permit.sourceRevision
                    })
                    timeout.cancel()
                    finish(success)
                }
            }
        }
    }

    private static func record(_ outcome: String) {
        Foundation.NotificationCenter.default.post(name: DiagnosticEventContract.notificationName, object: nil,
            userInfo: ["schema": 1, "feature": "privacy", "stage": "recovery", "outcome": outcome])
    }

    private final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true
        private let expires: TimeInterval
        let sourceRevision: UUID
        init(sourceRevision: UUID, expiresAt: TimeInterval) {
            self.sourceRevision = sourceRevision
            expires = min(expiresAt, ProcessInfo.processInfo.systemUptime + 18)
        }
        var remaining: TimeInterval { max(0, expires - ProcessInfo.processInfo.systemUptime) }
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid && ProcessInfo.processInfo.systemUptime < expires }
        func cancel() { lock.lock(); valid = false; lock.unlock() }
    }
}

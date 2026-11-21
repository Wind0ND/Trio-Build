import Foundation

public enum ActivityLifecycleState: Equatable, Sendable { case active, stale, ended, dismissed }
public enum ActivityLifecycleAction: Equatable, Sendable { case update, create, waitForForeground, end }
public enum ActivityLifecyclePolicy {
    public static func action(state: ActivityLifecycleState?, foreground: Bool, enabled: Bool) -> ActivityLifecycleAction { .update }
}

@MainActor public final class ActivityPublicationQueue {
    public init() {}
    public func run(_ operation: @escaping @MainActor () async -> Void) async { await operation() }
}

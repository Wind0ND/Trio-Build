import Foundation

public enum ActivityLifecycleState: Equatable, Sendable { case active, stale, ended, dismissed }
public enum ActivityLifecycleAction: Equatable, Sendable { case update, create, waitForForeground, end }
public enum ActivityLifecyclePolicy {
    public static func action(state: ActivityLifecycleState?, foreground: Bool, enabled: Bool) -> ActivityLifecycleAction {
        guard enabled else { return .end }
        switch state {
        case .active, .stale: return .update
        case .ended, .dismissed, nil: return foreground ? .create : .waitForForeground
        }
    }
}

@MainActor public final class ActivityPublicationQueue {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0
    public init() {}
    public func run(coalescing: Bool = false, _ operation: @escaping @MainActor () async -> Void) async {
        generation &+= 1
        let mine = generation
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
        if generation == mine { tail = nil }
    }
}

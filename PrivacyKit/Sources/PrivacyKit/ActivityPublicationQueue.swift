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
    private final class Pending {
        var operation: (@MainActor () async -> Void)?
        var task: Task<Void, Never>?
        init(_ operation: @escaping @MainActor () async -> Void) { self.operation = operation }
    }
    private var replaceable: Pending?
    private var generation: UInt64 = 0
    public init() {}
    public func run(coalescing: Bool = false, _ operation: @escaping @MainActor () async -> Void) async {
        if coalescing, let pending = replaceable {
            pending.operation = operation
            await pending.task?.value
            return
        }
        generation &+= 1
        let mine = generation
        let previous = tail
        let pending = Pending(operation)
        // An explicit operation is a barrier: later snapshots must remain behind it.
        replaceable = coalescing ? pending : nil
        let task = Task { @MainActor in
            await previous?.value
            if self.replaceable === pending { self.replaceable = nil }
            let latest = pending.operation
            pending.operation = nil
            await latest?()
        }
        pending.task = task
        tail = task
        await task.value
        if generation == mine { tail = nil }
    }
}

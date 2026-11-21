import Foundation

/// Prevent a newly scheduled request from being removed while retiring its previous delivery.
public final class NotificationRetirementBarrier: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    public init() {}
    public func serialized<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return operation()
    }
    public func isRetiring(_ key: String) -> Bool { false }
    public func schedule(_ key: String, write: @escaping () -> Void) { write() }
    public func retire(_ key: String, capture: (@escaping () -> Void) -> Void, remove: @escaping () -> Void) {
        capture { remove() }
    }
}

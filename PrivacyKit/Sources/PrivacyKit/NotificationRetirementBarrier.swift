import Foundation

/// Prevent a newly scheduled request from being removed while retiring its previous delivery.
public final class NotificationRetirementBarrier: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var retiring = Set<String>()
    private var pending: [String: () -> Void] = [:]
    public init() {}
    public func serialized<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return operation()
    }
    public func isRetiring(_ key: String) -> Bool { serialized { retiring.contains(key) } }
    public func schedule(_ key: String, write: @escaping () -> Void) {
        serialized {
            if retiring.contains(key) { pending[key] = write } else { write() }
        }
    }
    public func retire(_ key: String, capture: (@escaping () -> Void) -> Void, remove: @escaping () -> Void) {
        serialized {
            pending.removeValue(forKey: key)
            guard retiring.insert(key).inserted else { return }
            capture {
                self.serialized {
                    guard self.retiring.contains(key) else { return }
                    remove()
                    self.retiring.remove(key)
                    let latest = self.pending.removeValue(forKey: key)
                    latest?()
                }
            }
        }
    }
}

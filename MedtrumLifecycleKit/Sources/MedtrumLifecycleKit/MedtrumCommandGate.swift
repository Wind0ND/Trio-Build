import Foundation

/// Serial command slot. Validation belongs after waiting, before any command is transmitted.
public final class MedtrumCommandGate: @unchecked Sendable {
    private let slot = DispatchSemaphore(value: 1)
    public init() {}

    public func perform<T>(isValid: () -> Bool, operation: () -> T) -> T? {
        slot.wait()
        defer { slot.signal() }
        guard isValid() else { return nil }
        return operation()
    }
}

import Foundation

/// In-process rendezvous for a LiveActivityIntent that can arrive before services finish loading.
@MainActor public final class PrivateRecoveryBridge {
    public static let shared = PrivateRecoveryBridge()
    public struct Request: Sendable {
        public let expiresAtUptime: TimeInterval
        public let isCurrent: @MainActor @Sendable () -> Bool
        public let complete: @MainActor @Sendable (Bool) -> Void
    }
    public typealias Handler = @MainActor (Request) -> Void
    private let timeout: TimeInterval
    private var handler: Handler?
    private var token: UUID?
    private var started = false
    private var expiresAtUptime: TimeInterval = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var expiration: Task<Void, Never>?
    public init(timeout: TimeInterval = 20) { self.timeout = max(0.01, min(20, timeout)) }
    public func configure(_ handler: @escaping Handler) { self.handler = handler; startIfReady() }
    public func request() async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if token == nil {
                let id = UUID()
                token = id
                expiresAtUptime = ProcessInfo.processInfo.systemUptime + timeout
                expiration = Task { [weak self] in
                    guard let delay = self?.timeout else { return }
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    self?.finish(id, success: false)
                }
            }
            startIfReady()
        }
    }
    private func startIfReady() {
        guard let handler, let id = token, !started else { return }
        guard ProcessInfo.processInfo.systemUptime < expiresAtUptime else { finish(id, success: false); return }
        started = true
        handler(Request(expiresAtUptime: expiresAtUptime, isCurrent: { [weak self] in
                            guard let self else { return false }
                            return self.token == id && ProcessInfo.processInfo.systemUptime < self.expiresAtUptime
                        },
                        complete: { [weak self] success in self?.finish(id, success: success) }))
    }
    private func finish(_ id: UUID, success: Bool) {
        guard token == id else { return }
        token = nil; started = false
        expiration?.cancel(); expiration = nil
        let continuations = waiters; waiters.removeAll()
        continuations.forEach { $0.resume(returning: success) }
    }
}

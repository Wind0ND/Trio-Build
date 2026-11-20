import Foundation

/// In-process rendezvous for a LiveActivityIntent that can arrive before services finish loading.
@MainActor public final class PrivateRecoveryBridge {
    public static let shared = PrivateRecoveryBridge()
    public struct Request {
        public let isCurrent: @MainActor () -> Bool
        public let complete: @MainActor (Bool) -> Void
    }
    public typealias Handler = @MainActor (Request) -> Void
    public init(timeout: TimeInterval = 20) {}
    public func configure(_ handler: @escaping Handler) {}
    public func request() async -> Bool { false }
}

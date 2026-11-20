import Foundation

/// Fetches into a local snapshot; it never mutates a shared observable model.
@MainActor public enum AuthorizedSnapshot {
    public static func publish<Value>(fetch: () async throws -> Value, isAuthorized: @escaping @MainActor () -> Bool,
                                     commit: (Value, @escaping @MainActor () -> Bool) async -> Void) async throws {
        guard isAuthorized() else { return }
        let snapshot = try await fetch()
        guard isAuthorized() else { return }
        await commit(snapshot, isAuthorized)
    }
}

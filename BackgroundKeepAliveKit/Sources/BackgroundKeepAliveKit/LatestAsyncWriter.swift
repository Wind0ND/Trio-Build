import Foundation

/// Serializes asynchronous system writes and always finishes by applying the newest desired state.
/// Cancelling a Task cannot cancel an already submitted notification-center request.
@MainActor final class LatestAsyncWriter<Value: Equatable> {
    private var desired: (revision: UInt64, value: Value)?
    private var revision: UInt64 = 0
    private var writing = false
    private let apply: (Value) async -> Void

    init(apply: @escaping (Value) async -> Void) { self.apply = apply }

    func set(_ value: Value, force: Bool = false) {
        guard force || desired?.value != value else { return }
        revision &+= 1
        desired = (revision, value)
        guard !writing else { return }
        writing = true
        Task {
            var applied: UInt64?
            while let next = desired, applied != next.revision {
                await apply(next.value)
                applied = next.revision
            }
            writing = false
        }
    }
}

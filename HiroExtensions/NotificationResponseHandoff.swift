import Foundation

/// Buffers launch-time responses without constructing the application services.
@MainActor final class HiroNotificationResponseHandoff<Response> {
    private var pending: [Response] = []
    private var handler: ((Response) -> Void)?

    func receive(_ response: Response) {
        if let handler { handler(response) }
        else { pending.append(response) }
    }

    func attach(handler: @escaping (Response) -> Void) {
        self.handler = handler
        let buffered = pending
        pending.removeAll()
        buffered.forEach(handler)
    }
}

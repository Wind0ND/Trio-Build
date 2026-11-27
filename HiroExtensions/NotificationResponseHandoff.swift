import Foundation

/// Buffers launch-time responses without constructing the application services.
@MainActor final class HiroNotificationResponseHandoff<Response> {
    func receive(_ response: Response) {}
    func attach(handler: @escaping (Response) -> Void) {}
}

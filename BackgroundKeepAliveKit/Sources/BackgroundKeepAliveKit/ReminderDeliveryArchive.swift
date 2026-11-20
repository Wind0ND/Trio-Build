import Foundation

@MainActor enum ReminderDeliveryArchive {
    static func captureBeforeRemoval(capture: () async -> [Date], record: (Date) -> Void,
                                     remove: () -> Void) async {
        remove()
        for date in await capture() { record(date) }
    }
}

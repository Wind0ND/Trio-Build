import Foundation

@MainActor enum ReminderDeliveryArchive {
    static func captureBeforeRemoval(capture: () async -> [Date], record: (Date) -> Void,
                                     remove: () -> Void) async {
        let delivered = await capture()
        delivered.forEach(record)
        if !delivered.isEmpty { remove() }
    }
}

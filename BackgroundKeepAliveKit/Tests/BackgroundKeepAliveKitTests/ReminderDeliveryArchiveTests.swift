import XCTest
@testable import BackgroundKeepAliveKit

final class ReminderDeliveryArchiveTests: XCTestCase {
    @MainActor func testSuspendedDeliveryIsCapturedBeforeBackgroundRecoveryClearsIt() async {
        let deadline = Date()
        var delivered = [deadline]
        var recorded: [Date] = []
        await ReminderDeliveryArchive.captureBeforeRemoval(capture: { delivered }, record: { recorded.append($0) }, remove: { delivered = [] })
        XCTAssertEqual(recorded, [deadline])
        XCTAssertTrue(delivered.isEmpty)
    }
    @MainActor func testSchedulingWithoutDeliveryCannotCreateHistory() async {
        var recorded = false
        await ReminderDeliveryArchive.captureBeforeRemoval(capture: { [] }, record: { _ in recorded = true }, remove: {})
        XCTAssertFalse(recorded)
    }
}

import Foundation
import XCTest
@testable import BackgroundKeepAliveKit

final class LatestAsyncWriterTests: XCTestCase {
    @MainActor func testLateAddFinishesBeforeTheLatestRemoveAndIntermediateUpdatesAreCoalesced() async {
        let started = expectation(description: "old add entered system")
        let removed = expectation(description: "latest remove applied")
        var release: CheckedContinuation<Void, Never>?
        var writes: [String] = []
        let writer = LatestAsyncWriter<String> { value in
            if value == "old-add" {
                await withCheckedContinuation { continuation in release = continuation; started.fulfill() }
            }
            writes.append(value)
            if value == "remove" { removed.fulfill() }
        }
        writer.set("old-add")
        await fulfillment(of: [started], timeout: 2)
        writer.set("new-add")
        writer.set("remove")
        release?.resume()
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(writes, ["old-add", "remove"])
    }

    @MainActor func testTheSameDesiredRequestDoesNotRearmAnOutage() async {
        let applied = expectation(description: "request applied once")
        applied.assertForOverFulfill = true
        var count = 0
        let writer = LatestAsyncWriter<Int> { _ in count += 1; applied.fulfill() }
        writer.set(1)
        writer.set(1)
        await fulfillment(of: [applied], timeout: 2)
        writer.set(1)
        await Task.yield()
        XCTAssertEqual(count, 1)
    }
}

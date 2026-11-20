import XCTest
@testable import PrivacyKit

final class PrivateRecoveryBridgeTests: XCTestCase {
    @MainActor func testColdRequestWaitsAndConcurrentTapsCoalesce() async {
        let bridge = PrivateRecoveryBridge(timeout: 1)
        var starts = 0
        var request: PrivateRecoveryBridge.Request?
        let first = Task { await bridge.request() }
        let second = Task { await bridge.request() }
        await Task.yield()
        bridge.configure { starts += 1; request = $0 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(starts, 1)
        request?.complete(true)
        let a = await first.value, b = await second.value
        XCTAssertTrue(a && b)
        XCTAssertFalse(request?.isCurrent() ?? true)
    }
    @MainActor func testTimeoutRejectsLateCompletionAndAllowsNextAttempt() async {
        let bridge = PrivateRecoveryBridge(timeout: 0.03)
        var requests: [PrivateRecoveryBridge.Request] = []
        bridge.configure { requests.append($0) }
        let first = await bridge.request()
        XCTAssertFalse(first)
        XCTAssertEqual(requests.count, 1)
        guard let old = requests.first else { return }
        let next = Task { await bridge.request() }
        for _ in 0..<10 { await Task.yield() }
        old.complete(true)
        XCTAssertFalse(old.isCurrent())
        XCTAssertEqual(requests.count, 2)
        requests.last?.complete(true)
        let result = await next.value
        XCTAssertTrue(result)
    }
}

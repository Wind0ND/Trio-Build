import XCTest
@testable import PrivacyKit

final class AuthorizedSnapshotTests: XCTestCase {
    @MainActor func testExpiredOrReplacedSourceDuringFetchCannotPublishOrMutateSharedState() async throws {
        var current = true
        var writes = 0
        try await AuthorizedSnapshot.publish(fetch: {
            await Task.yield(); current = false; return 123
        }, isAuthorized: { current }, commit: { _, _ in writes += 1 })
        XCTAssertEqual(writes, 0)
    }
    @MainActor func testAuthorizationIsPreservedAcrossDelayedActivityPreparation() async throws {
        var current = true
        var writes = 0
        try await AuthorizedSnapshot.publish(fetch: { 123 }, isAuthorized: { current }, commit: { _, authorized in
            await Task.yield(); current = false
            if authorized() { writes += 1 }
        })
        XCTAssertEqual(writes, 0)
    }
}

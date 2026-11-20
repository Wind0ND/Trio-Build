import XCTest
@testable import PrivacyKit

final class AlertJournalRepositoryTests: XCTestCase {
    func testUnavailableReadDoesNotOverwriteHistoryAndPendingEventsMergeOnRetry() throws {
        let now = Date()
        let old = JournalAlert(source: "pump", kind: "old", title: "original", body: "body", issuedAt: now - 10)
        var original = AlertJournal(); original.issue(old, now: now)
        var disk = try JSONEncoder().encode(original)
        var accessible = false
        var writes = 0
        let store = AlertJournalRepository(read: {
            guard accessible else { throw CocoaError(.fileReadNoPermission) }
            return disk
        }, write: { disk = $0; writes += 1 })
        XCTAssertEqual(writes, 0)
        let new = JournalAlert(source: "CGM", kind: "new", title: "new", body: "body", issuedAt: now)
        store.update(now: now) { $0.issue(new, now: now) }
        XCTAssertEqual(writes, 0)
        accessible = true
        store.retry()
        XCTAssertEqual(Set(store.recent(now: now).map(\.id)), Set([old.id, new.id]))
        XCTAssertEqual(Set(try JSONDecoder().decode(AlertJournal.self, from: disk).entries.map(\.id)), Set([old.id, new.id]))
    }
}

import XCTest
@testable import PrivacyKit

final class AlertJournalTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func entry(_ date: Date, source: String = "CGM", kind: String = "low") -> JournalAlert {
        .init(source: source, kind: kind, title: "Original", body: "Private detail", issuedAt: date)
    }
    func testResolutionRetainsOriginalAndNeverBecomesActiveQueue() {
        var journal = AlertJournal()
        let item = entry(now)
        journal.issue(item, now: now)
        journal.acknowledge(source: "CGM", kind: "low", at: now.addingTimeInterval(10))
        journal.resolve(source: "CGM", kind: "low", at: now.addingTimeInterval(20))
        let result = journal.recent(now: now.addingTimeInterval(30))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.body, "Private detail")
        XCTAssertEqual(result.first?.resolvedAt, now.addingTimeInterval(20))
        XCTAssertEqual(result.first?.acknowledgedAt, now.addingTimeInterval(10))
    }
    func testRetentionOrderingDuplicatesAndDistinctReissues() {
        var journal = AlertJournal()
        let item = entry(now.addingTimeInterval(-20))
        for row in [entry(now.addingTimeInterval(-86_401)), item, item, entry(now)] { journal.issue(row, now: now) }
        XCTAssertEqual(journal.recent(now: now).map(\.issuedAt), [now, item.issuedAt])
        journal.prune(now: now.addingTimeInterval(86_401))
        XCTAssertTrue(journal.entries.isEmpty)
    }
    func testLateLifecycleCannotResolveNewerIssueOrDifferentSource() {
        var journal = AlertJournal()
        journal.issue(entry(now), now: now)
        journal.issue(entry(now, source: "Pump"), now: now)
        journal.resolve(source: "CGM", kind: "low", at: now.addingTimeInterval(-1))
        XCTAssertEqual(journal.entries.count, 2)
        XCTAssertTrue(journal.entries.allSatisfy { $0.resolvedAt == nil })
    }
    func testAcknowledgingNewEpisodeDoesNotRewriteClosedOriginal() {
        var journal = AlertJournal()
        let old = entry(now.addingTimeInterval(-20))
        journal.issue(old, now: now)
        journal.resolve(source: "CGM", kind: "low", at: now.addingTimeInterval(-10))
        let current = entry(now)
        journal.issue(current, now: now)
        journal.acknowledge(source: "CGM", kind: "low", at: now)
        XCTAssertNil(journal.entries.first { $0.id == old.id }?.acknowledgedAt)
        XCTAssertEqual(journal.entries.first { $0.id == current.id }?.acknowledgedAt, now)
    }
}

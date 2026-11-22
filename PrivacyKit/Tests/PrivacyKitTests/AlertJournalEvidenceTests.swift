import Foundation
import XCTest
@testable import PrivacyKit

final class AlertJournalEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testThreeDayPlanSurvivesPruningUntilDeliveredThenExpiresFromDelivery() {
        var journal = AlertJournal()
        let due = now.addingTimeInterval(3 * 86_400)
        let plan = JournalAlert(source: "pump", kind: "expiry", title: "replacement", body: "",
                                issuedAt: now, scheduledFor: due)
        journal.issue(plan, now: now)
        journal.prune(now: due.addingTimeInterval(-60))
        XCTAssertEqual(journal.entries.map(\.id), [plan.id])
        XCTAssertTrue(journal.triggeredHistory(now: due).isEmpty)
        journal.prune(now: due.addingTimeInterval(10))
        XCTAssertTrue(journal.markTriggered(id: plan.id, at: due, delivered: true))
        XCTAssertEqual(journal.triggeredHistory(now: due.addingTimeInterval(86_399)).map(\.id), [plan.id])
        journal.prune(now: due.addingTimeInterval(86_401))
        XCTAssertTrue(journal.entries.isEmpty)
    }

    func testCancelledFuturePlanExpiresAfterClosure() {
        var journal = AlertJournal()
        let plan = JournalAlert(source: "pump", kind: "expiry", title: "", body: "",
                                issuedAt: now, scheduledFor: now.addingTimeInterval(7 * 86_400))
        journal.issue(plan, now: now)
        journal.resolve(source: plan.source, kind: plan.kind, at: now.addingTimeInterval(60))
        journal.prune(now: now.addingTimeInterval(2 * 86_400))
        XCTAssertTrue(journal.entries.isEmpty)
    }

    func testFuturePlansAndCancelledPlansAreNotTriggeredHistory() {
        var journal = AlertJournal()
        let plan = JournalAlert(source: "trio.aps", kind: "loop.notActive.w1", title: "plan", body: "", issuedAt: now,
                                scheduledFor: now.addingTimeInterval(1200))
        journal.issue(plan, now: now)
        XCTAssertTrue(journal.triggeredHistory(now: now.addingTimeInterval(1300)).isEmpty)
        journal.resolve(source: plan.source, kind: plan.kind, at: now.addingTimeInterval(300))
        XCTAssertEqual(journal.entries.first?.cancelledAt, now.addingTimeInterval(300))
        XCTAssertTrue(journal.triggeredHistory(now: now.addingTimeInterval(1300)).isEmpty)
    }

    func testObservedTriggerMarksOnlyItsExactOccurrence() {
        var journal = AlertJournal()
        let old = JournalAlert(source: "trio.aps", kind: "same", title: "old", body: "", issuedAt: now)
        let new = JournalAlert(source: "trio.aps", kind: "same", title: "new", body: "", issuedAt: now.addingTimeInterval(1))
        journal.issue(old, now: now)
        journal.issue(new, now: now.addingTimeInterval(1))
        journal.markTriggered(id: old.id, at: now.addingTimeInterval(2))
        XCTAssertEqual(journal.triggeredHistory(now: now.addingTimeInterval(3)).map(\.id), [old.id])
        journal.resolve(source: old.source, kind: old.kind, at: now.addingTimeInterval(4))
        XCTAssertEqual(journal.entries.first?.resolvedAt, now.addingTimeInterval(4))
        XCTAssertNil(journal.entries.first?.cancelledAt)
    }

    func testLateTriggerCannotReviveCancelledPlanOrInventFutureEvent() {
        var journal = AlertJournal()
        let plan = JournalAlert(source: "trio.aps", kind: "later", title: "", body: "", issuedAt: now,
                                scheduledFor: now.addingTimeInterval(1200))
        journal.issue(plan, now: now)
        journal.resolve(source: plan.source, kind: plan.kind, at: now.addingTimeInterval(10))
        journal.markTriggered(id: plan.id, at: now.addingTimeInterval(1200))
        XCTAssertTrue(journal.triggeredHistory(now: now.addingTimeInterval(1300)).isEmpty)
        XCTAssertNil(journal.entries.first?.triggeredAt)
    }

    func testOldRecordsDecodeWithoutClaimingTheyWereTriggered() throws {
        let item = JournalAlert(source: "test", kind: "old", title: "old", body: "", issuedAt: now)
        let data = try JSONEncoder().encode(item)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "triggeredAt"); json.removeValue(forKey: "cancelledAt")
        let old = try JSONDecoder().decode(JournalAlert.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.triggeredAt)
        var journal = AlertJournal(); journal.issue(old, now: now)
        XCTAssertTrue(journal.triggeredHistory(now: now).isEmpty)
    }

    func testObservedDeliveryBeforeCancellationCanBeImportedLater() {
        var journal = AlertJournal()
        let plan = JournalAlert(source: "trio.aps", kind: "late-import", title: "", body: "", issuedAt: now,
                                scheduledFor: now.addingTimeInterval(1200))
        journal.issue(plan, now: now)
        journal.resolve(source: plan.source, kind: plan.kind, at: now.addingTimeInterval(1300))
        journal.markTriggered(id: plan.id, at: now.addingTimeInterval(1201))
        XCTAssertEqual(journal.triggeredHistory(now: now.addingTimeInterval(1400)).map(\.id), [plan.id])
        XCTAssertEqual(journal.entries.first?.triggeredAt, now.addingTimeInterval(1201))
        XCTAssertNil(journal.entries.first?.cancelledAt)
    }
}

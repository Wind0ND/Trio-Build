import Foundation
import XCTest
@testable import PrivacyKit

final class FinalReviewRegressionTests: XCTestCase {
    func testRetirementCapturesAndRemovesOldDeliveryBeforeRearmingTheSameIdentifier() {
        let barrier = NotificationRetirementBarrier()
        var trace: [String] = []
        var complete: (() -> Void)?
        barrier.retire("same", capture: { finish in trace.append("capture"); complete = finish },
                       remove: { trace.append("remove-old") })
        barrier.schedule("same") { trace.append("obsolete-plan") }
        barrier.schedule("same") { trace.append("latest-plan") }
        XCTAssertEqual(trace, ["capture"])
        complete?()
        XCTAssertEqual(trace, ["capture", "remove-old", "latest-plan"])
    }

    func testExactSystemReceiptAfterRetractionIsPreservedOnceWithoutInventingRecovery() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = JournalAlert(source: "test", kind: "same", title: "", body: "", issuedAt: now,
                                scheduledFor: now.addingTimeInterval(60))
        var journal = AlertJournal(); journal.issue(plan, now: now)
        journal.resolve(source: plan.source, kind: plan.kind, at: now.addingTimeInterval(59))
        XCTAssertTrue(journal.markTriggered(id: plan.id, at: now.addingTimeInterval(61), delivered: true))
        XCTAssertEqual(journal.entries.first?.deliveredAt, now.addingTimeInterval(61))
        XCTAssertFalse(journal.markTriggered(id: plan.id, at: now.addingTimeInterval(61), delivered: true))
        XCTAssertEqual(journal.entries.first?.resolvedAt, now.addingTimeInterval(59))
    }

    func testRepeatedTimerObservationDoesNotEmitAnotherTransition() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = JournalAlert(source: "test", kind: "now", title: "", body: "", issuedAt: now)
        var journal = AlertJournal(); journal.issue(item, now: now)
        XCTAssertTrue(journal.markTriggered(id: item.id, at: now))
        XCTAssertFalse(journal.markTriggered(id: item.id, at: now.addingTimeInterval(1)))
    }
}

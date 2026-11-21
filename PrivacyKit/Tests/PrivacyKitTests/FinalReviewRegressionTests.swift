import Foundation
import XCTest
@testable import PrivacyKit

final class FinalReviewRegressionTests: XCTestCase {
    @MainActor func testBlockedPublicationCoalescesBurstBeforeTheNextExplicitBarrier() async {
        let queue = ActivityPublicationQueue()
        let gate = ReviewGate()
        var trace: [Int] = []
        let first = Task { await queue.run { await gate.wait() } }
        while !gate.entered { await Task.yield() }
        var pending: [Task<Void, Never>] = []
        for index in 0..<30 {
            pending.append(Task { await queue.run(coalescing: true) { trace.append(index) } })
            for _ in 0..<3 { await Task.yield() }
        }
        let end = Task { await queue.run { trace.append(-1) } }
        for _ in 0..<10 { await Task.yield() }
        gate.release()
        await first.value
        for item in pending { await item.value }
        await end.value
        XCTAssertEqual(trace, [29, -1])
    }

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

@MainActor private final class ReviewGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func release() { continuation?.resume(); continuation = nil }
}

import Foundation
import XCTest
@testable import MedtrumLifecycleKit

final class MedtrumShortTempBasalTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let session = Data([1, 2, 3, 4])
    private let command = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func plan(minutes: Int = 5, rate: Double = 6) -> MedtrumShortTempBasal {
        MedtrumShortTempBasal(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
                             commandID: command, rate: rate, minutes: minutes, requestedAt: start)!
    }

    func testEstimatedTotalUsesHoursRatherThanMinutes() {
        XCTAssertEqual(plan().estimatedUnits, 0.50, accuracy: 0.000001)
        XCTAssertEqual(plan(minutes: 25).estimatedUnits, 2.50, accuracy: 0.000001)
        XCTAssertEqual(plan(minutes: 10, rate: 1.2).estimatedUnits, 0.20, accuracy: 0.000001)
    }

    func testOnlyFiveMinuteStepsFromFiveThroughTwentyFiveAreAccepted() {
        for minutes in [5, 10, 15, 20, 25] { XCTAssertEqual(plan(minutes: minutes).minutes, minutes) }
        for minutes in [-5, 0, 1, 6, 26, 30] {
            XCTAssertNil(MedtrumShortTempBasal(sessionID: session, sessionStartedAt: start,
                                             commandID: command, rate: 6, minutes: minutes, requestedAt: start))
        }
        for rate in [Double.nan, .infinity, -1, 0] {
            XCTAssertNil(MedtrumShortTempBasal(sessionID: session, sessionStartedAt: start,
                                             commandID: command, rate: rate, minutes: 5, requestedAt: start))
        }
    }

    func testDeadlineUsesPumpConfirmedStartAndCannotCancelBeforeIt() throws {
        let confirmed = try XCTUnwrap(plan().confirmed(startedAt: start.addingTimeInterval(3), observedAt: start.addingTimeInterval(4)))
        XCTAssertEqual(confirmed.targetEnd, start.addingTimeInterval(303))
        XCTAssertFalse(canCancel(confirmed, at: start.addingTimeInterval(302)))
        XCTAssertTrue(canCancel(confirmed, at: start.addingTimeInterval(303)))
        XCTAssertFalse(canCancel(plan(), at: start.addingTimeInterval(600)), "Unconfirmed intent must not cancel another segment")
        XCTAssertNil(plan().confirmed(startedAt: start.addingTimeInterval(-60), observedAt: start))
        XCTAssertNil(plan().confirmed(startedAt: start.addingTimeInterval(60), observedAt: start))
    }

    func testOldTaskCannotCancelNewPatchCommandRateOrAutomaticDose() throws {
        let confirmed = try XCTUnwrap(plan().confirmed(startedAt: start, observedAt: start))
        XCTAssertTrue(canCancel(confirmed, at: start.addingTimeInterval(300)))
        let now = start.addingTimeInterval(600)
        XCTAssertFalse(confirmed.canCancel(sessionID: Data([9]), sessionStartedAt: start.addingTimeInterval(-3600), commandID: command, startDate: start, rate: 6, automatic: false, now: now))
        XCTAssertFalse(confirmed.canCancel(sessionID: session, sessionStartedAt: start, commandID: command, startDate: start, rate: 6, automatic: false, now: now))
        XCTAssertFalse(confirmed.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600), commandID: UUID(), startDate: start, rate: 6, automatic: false, now: now))
        XCTAssertFalse(confirmed.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600), commandID: command, startDate: start.addingTimeInterval(60), rate: 6, automatic: false, now: now))
        XCTAssertFalse(confirmed.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600), commandID: command, startDate: start, rate: 1, automatic: false, now: now))
        XCTAssertFalse(confirmed.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600), commandID: command, startDate: start, rate: 6, automatic: true, now: now))
    }

    func testRestartRetainsDeadlineAndCommandIdentity() throws {
        var confirmed = try XCTUnwrap(plan().confirmed(startedAt: start, observedAt: start))
        confirmed.cancellationFailed = true
        let restored = try JSONDecoder().decode(MedtrumShortTempBasal.self, from: JSONEncoder().encode(confirmed))
        XCTAssertEqual(restored, confirmed)
        XCTAssertTrue(canCancel(restored, at: start.addingTimeInterval(301)))
        XCTAssertTrue(restored.cancellationFailed)
    }

    private func canCancel(_ plan: MedtrumShortTempBasal, at now: Date) -> Bool {
        plan.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600), commandID: command,
                       startDate: plan.confirmedStart ?? start, rate: 6, automatic: false, now: now)
    }
}

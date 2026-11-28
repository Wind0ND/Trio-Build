import Foundation
import XCTest
@testable import MedtrumLifecycleKit

final class MedtrumShortTempBasalTests: XCTestCase {
    func testNativeTimingPersistsAndUsesRequestedMinutes() throws {
        var intent = plan(minutes: 1)
        intent.nativeTiming = true
        let restored = try JSONDecoder().decode(MedtrumShortTempBasal.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.nativeTiming, true)
        XCTAssertEqual(restored.nativeDuration, 60)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
        legacyJSON.removeValue(forKey: "nativeTiming")
        let legacy = try JSONDecoder().decode(MedtrumShortTempBasal.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(legacy.nativeTiming)
        XCTAssertEqual(legacy.nativeDuration, 1800)
    }

    func testLongAutomaticCompanionKeepsIdentityAndAbsoluteEnd() throws {
        var intent = try XCTUnwrap(MedtrumShortTempBasal(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
            commandID: command, rate: 0, minutes: 60, requestedAt: start, automatic: true))
        intent.absoluteEnd = start.addingTimeInterval(3550)
        let restored = try JSONDecoder().decode(MedtrumShortTempBasal.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.targetEnd, start.addingTimeInterval(3550))
    }

    func testSetCheckpointTimeIsAfterRealBaselineWithoutReopeningCompanionWindow() throws {
        var intent = plan(minutes: 1)
        intent.absoluteEnd = start.addingTimeInterval(60)
        let prepared = try XCTUnwrap(intent.preparedForWrite(at: start.addingTimeInterval(5), uptime: 100))
        XCTAssertEqual(prepared.requestedAt, start.addingTimeInterval(5))
        XCTAssertEqual(prepared.targetEnd, start.addingTimeInterval(60))
    }

    func testWallClockRollbackCannotDelayMonotonicCancellation() throws {
        var intent = plan(minutes: 1)
        intent.requestedUptime = 100
        intent.deadlineUptime = 160
        XCTAssertTrue(intent.deadlineHasPassed(at: start.addingTimeInterval(-3600), uptime: 160))
        XCTAssertFalse(intent.deadlineHasPassed(at: start.addingTimeInterval(10), uptime: 110))
    }

    func testAutomaticCompanionCanBeZeroAndCannotExtendOriginalDeadline() throws {
        var intent = try XCTUnwrap(MedtrumShortTempBasal(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
            commandID: command, rate: 0, minutes: 29, requestedAt: start, automatic: true))
        intent.absoluteEnd = start.addingTimeInterval(1700)
        let confirmed = try XCTUnwrap(intent.confirmed(startedAt: start.addingTimeInterval(3), observedAt: start.addingTimeInterval(4)))
        XCTAssertEqual(confirmed.targetEnd, start.addingTimeInterval(1700))
        XCTAssertFalse(confirmed.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
            commandID: command, startDate: start.addingTimeInterval(3), rate: 0, automatic: false, now: start.addingTimeInterval(1700)))
        XCTAssertTrue(confirmed.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
            commandID: command, startDate: start.addingTimeInterval(3), rate: 0, automatic: true, now: start.addingTimeInterval(1700)))
    }

    func testRestoredAutomaticPulseCanCancelOnlyItsAutomaticDoseAtDeadline() throws {
        let confirmed = try XCTUnwrap(plan(minutes: 1).confirmed(startedAt: start, observedAt: start))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmed)) as? [String: Any])
        json["automaticPulse"] = true
        let restored = try JSONDecoder().decode(MedtrumShortTempBasal.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
            commandID: command, startDate: start, rate: 6, automatic: true, now: start.addingTimeInterval(60)))
        XCTAssertFalse(restored.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
            commandID: command, startDate: start, rate: 6, automatic: false, now: start.addingTimeInterval(60)))
    }

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

    func testUnsupportedShortMinutesAndInvalidRatesAreRejected() {
        for minutes in [5, 10, 15, 20, 25] { XCTAssertEqual(plan(minutes: minutes).minutes, minutes) }
        for minutes in [-5, 0, 11, 26, 30] {
            XCTAssertNil(MedtrumShortTempBasal(sessionID: session, sessionStartedAt: start,
                                             commandID: command, rate: 6, minutes: minutes, requestedAt: start))
        }
        for rate in [Double.nan, .infinity, -1, 0] {
            XCTAssertNil(MedtrumShortTempBasal(sessionID: session, sessionStartedAt: start,
                                             commandID: command, rate: rate, minutes: 5, requestedAt: start))
        }
    }

    func testOneThroughFourMinuteSessionsKeepExactDeadlinesAndPersistIdentity() throws {
        for (minutes, total) in [(1, 0.1), (2, 0.2), (3, 0.3), (4, 0.4), (6, 0.6), (7, 0.7), (8, 0.8), (9, 0.9)] {
            let intent = try XCTUnwrap(MedtrumShortTempBasal(
                sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600),
                commandID: command, rate: 6, minutes: minutes, requestedAt: start))
            let confirmed = try XCTUnwrap(intent.confirmed(startedAt: start, observedAt: start))
            let end = start.addingTimeInterval(Double(minutes) * 60)
            XCTAssertEqual(confirmed.targetEnd, end)
            XCTAssertEqual(confirmed.estimatedUnits, total, accuracy: 0.000001)
            XCTAssertFalse(canCancel(confirmed, at: end.addingTimeInterval(-1)))
            XCTAssertTrue(canCancel(confirmed, at: end))
            let restored = try JSONDecoder().decode(MedtrumShortTempBasal.self, from: JSONEncoder().encode(confirmed))
            XCTAssertEqual(restored.commandID, command)
            XCTAssertEqual(restored.targetEnd, end)
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

    func testAcknowledgedStartHandlesPumpClockOffsetAndBluetoothQueueDelay() throws {
        let skewed = try XCTUnwrap(plan().confirmed(startedAt: start.addingTimeInterval(600), observedAt: start.addingTimeInterval(3), clockOffset: 600, sequence: 42, acknowledged: true))
        XCTAssertEqual(skewed.confirmedStart, start)
        XCTAssertEqual(skewed.targetEnd, start.addingTimeInterval(300))
        XCTAssertEqual(skewed.pumpStart, start.addingTimeInterval(600))
        XCTAssertEqual(skewed.segmentSequence, 42)
        let queued = try XCTUnwrap(plan().confirmed(startedAt: start.addingTimeInterval(90), observedAt: start.addingTimeInterval(91), sequence: 43, acknowledged: true))
        XCTAssertEqual(queued.targetEnd, start.addingTimeInterval(390))
        let rounded = try XCTUnwrap(plan().confirmed(startedAt: start.addingTimeInterval(1), observedAt: start.addingTimeInterval(0.5), acknowledged: true))
        XCTAssertEqual(rounded.confirmedStart, start.addingTimeInterval(0.5), "Do not place the local start in the future due to pump timestamp rounding")
    }

    func testConfirmedEndToleratesClockQuantizationWithoutInventingFutureDelivery() throws {
        let confirmed = try XCTUnwrap(plan().confirmed(startedAt: start, observedAt: start))
        XCTAssertEqual(confirmed.confirmedEnd(pumpEnd: start.addingTimeInterval(300), observedAt: start.addingTimeInterval(300.4), clockOffset: -0.8), start.addingTimeInterval(300.4))
        XCTAssertNil(confirmed.confirmedEnd(pumpEnd: start.addingTimeInterval(300), observedAt: start.addingTimeInterval(300.4), clockOffset: -60))
        XCTAssertNil(confirmed.confirmedEnd(pumpEnd: start.addingTimeInterval(-60), observedAt: start.addingTimeInterval(1), clockOffset: 0))
        XCTAssertEqual(confirmed.confirmedEnd(pumpEnd: start.addingTimeInterval(1800.8), observedAt: start.addingTimeInterval(1801), clockOffset: 0), start.addingTimeInterval(1800))
    }

    private func canCancel(_ plan: MedtrumShortTempBasal, at now: Date) -> Bool {
        plan.canCancel(sessionID: session, sessionStartedAt: start.addingTimeInterval(-3600), commandID: command,
                       startDate: plan.confirmedStart ?? start, rate: 6, automatic: false, now: now)
    }
}

import Foundation
import XCTest
@testable import PrivacyKit

final class PrivacyPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSixSlotsRemainChronologicalAndKeepGaps() {
        let state = PrivacyActivityState(readings: [
            .init(mgDL: 108, date: now), .init(mgDL: 90, date: now.addingTimeInterval(-300)),
            .init(mgDL: 72, date: now.addingTimeInterval(-900))
        ], now: now)
        XCTAssertEqual(state.heights.count, 6)
        XCTAssertNil(state.heights[3])
        XCTAssertEqual(state.heights[2]!, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(state.heights[5]!, 0.5, accuracy: 0.0001)
    }

    func testFutureInvalidAndDuplicateSamplesDoNotAdvanceSlots() {
        let state = PrivacyActivityState(readings: [
            .init(mgDL: 900, date: now.addingTimeInterval(1)),
            .init(mgDL: .nan, date: now), .init(mgDL: 0, date: now),
            .init(mgDL: 90, date: now), .init(mgDL: 90, date: now)
        ], now: now)
        XCTAssertEqual(state.measuredAt, now)
        XCTAssertEqual(state.heights.compactMap { $0 }.count, 1)
        XCTAssertEqual(state.color, PrivacyColor.palette[2])
    }

    func testFreshnessUsesMeasurementAgeAndKeepsColor() {
        let state = PrivacyActivityState(readings: [.init(mgDL: 90, date: now)], now: now)
        XCTAssertFalse(state.isStale(at: now.addingTimeInterval(299)))
        XCTAssertFalse(state.isStale(at: now.addingTimeInterval(300)))
        XCTAssertFalse(state.isStale(at: now.addingTimeInterval(359)))
        XCTAssertTrue(state.isStale(at: now.addingTimeInterval(360)))
        XCTAssertEqual(state.staleDate, now.addingTimeInterval(360))
        XCTAssertEqual(state.color, PrivacyColor.palette[2])
    }

    func testHeightClampsAndUnknownData() {
        let empty = PrivacyActivityState(readings: [], now: now)
        XCTAssertTrue(empty.isStale(at: now))
        XCTAssertEqual(empty.color, .unknown)
        let high = PrivacyActivityState(readings: [.init(mgDL: 400, date: now)], now: now)
        XCTAssertEqual(high.heights[5], 1)
    }

    func testRecentRecoveredGridGetsDisplayTimeWithoutChangingMeasurementTime() {
        let measured = now.addingTimeInterval(-240)
        let state = PrivacyActivityState(
            readings: [.init(mgDL: 90, date: measured)], now: now, recoveredAt: now
        )
        XCTAssertEqual(state.measuredAt, measured)
        XCTAssertEqual(state.recoveredAt, now)
        XCTAssertEqual(state.staleDate, now.addingTimeInterval(360))
        XCTAssertFalse(state.isStale(at: now.addingTimeInterval(359)))
        XCTAssertTrue(state.isStale(at: now.addingTimeInterval(360)))
        let changedCover = state.replacingCover(Data([1, 2, 3]))
        XCTAssertEqual(changedCover.staleDate, state.staleDate)

        let old = PrivacyActivityState(
            readings: [.init(mgDL: 90, date: now.addingTimeInterval(-3600))], now: now, recoveredAt: now
        )
        XCTAssertNil(old.recoveredAt)
        XCTAssertTrue(old.isStale(at: now))
        let futureReceipt = PrivacyActivityState(
            readings: [.init(mgDL: 90, date: measured)], now: now, recoveredAt: now.addingTimeInterval(1)
        )
        XCTAssertNil(futureReceipt.recoveredAt)
    }

    func testExistingSnapshotsWithoutRecoveryFieldStillDecode() throws {
        let original = PrivacyActivityState(readings: [.init(mgDL: 90, date: now)], now: now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "recoveredAt")
        let decoded = try JSONDecoder().decode(PrivacyActivityState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.recoveredAt)
        XCTAssertEqual(decoded.measuredAt, original.measuredAt)
        XCTAssertEqual(decoded.staleDate, original.staleDate)
    }

    func testLinearHeightUsesTwelveAsTheDisplayCeiling() {
        for (mmolL, expected) in [(4.0, 1.0 / 3), (6.0, 0.5), (8.0, 2.0 / 3),
                                  (10.0, 5.0 / 6), (12.0, 1.0), (16.0, 1.0)] {
            let state = PrivacyActivityState(readings: [.init(mgDL: mmolL * 18, date: now)], now: now)
            XCTAssertEqual(state.heights[5]!, expected, accuracy: 0.0001)
            XCTAssertEqual(state.measuredAt, now)
            XCTAssertEqual(state.color, PrivacyPalette().color(mgDL: mmolL * 18))
        }
        let low = PrivacyActivityState(readings: [.init(mgDL: 10, date: now)], now: now)
        XCTAssertEqual(low.heights[5], 0.12)
    }

    func testPaletteIsContinuousAroundBoundariesAndRejectsInvalidSettings() {
        let palette = PrivacyPalette()
        for boundary in PrivacyPalette.defaultBoundaries {
            let left = palette.color(mgDL: (boundary - 0.0001) * 18)
            let right = palette.color(mgDL: (boundary + 0.0001) * 18)
            XCTAssertLessThan(abs(left.red - right.red), 0.001)
            XCTAssertLessThan(abs(left.green - right.green), 0.001)
            XCTAssertLessThan(abs(left.blue - right.blue), 0.001)
        }
        XCTAssertFalse(PrivacyPalette.isValid([3, 4, 4, 8, 12]))
        XCTAssertEqual(PrivacyPalette(boundaries: [.nan]).boundaries, PrivacyPalette.defaultBoundaries)
    }

    func testPredictionAndCarbsRemainCoolColors() {
        XCTAssertEqual(PrivacyGlucoseAlarm.carbsRequired.color, PrivacyColor.palette[1])
        XCTAssertEqual(PrivacyGlucoseAlarm.forecastedLow.color, PrivacyColor.palette[1])
        XCTAssertEqual(PrivacyGlucoseAlarm(identifier: "glucose.high.123"), .high)
        XCTAssertNil(PrivacyGlucoseAlarm(identifier: "pump.high.123"))
    }

    func testActivitySnapshotBoundsThumbnailAndRoundTrips() throws {
        let state = PrivacyActivityState(readings: [], now: now, cover: Data(repeating: 0, count: 1201))
        XCTAssertNil(state.cover)
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PrivacyActivityState.self, from: encoded), state)
    }

    func testCoverCanBeRemovedWithoutRefreshingStaleMeasurement() {
        let old = PrivacyActivityState(readings: [.init(mgDL: 90, date: now)], now: now, cover: Data([1, 2, 3]))
        let updated = old.replacingCover(nil)
        XCTAssertNil(updated.cover)
        XCTAssertEqual(updated.color, old.color)
        XCTAssertEqual(updated.heights, old.heights)
        XCTAssertEqual(updated.staleDate, old.staleDate)
    }
}

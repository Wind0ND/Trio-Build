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
        XCTAssertEqual(state.heights[2]!, 72.0 / 270, accuracy: 0.0001)
        XCTAssertEqual(state.heights[5]!, 108.0 / 270, accuracy: 0.0001)
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
        XCTAssertTrue(state.isStale(at: now.addingTimeInterval(300)))
        XCTAssertEqual(state.color, PrivacyColor.palette[2])
    }

    func testHeightClampsAndUnknownData() {
        let empty = PrivacyActivityState(readings: [], now: now)
        XCTAssertTrue(empty.isStale(at: now))
        XCTAssertEqual(empty.color, .unknown)
        let high = PrivacyActivityState(readings: [.init(mgDL: 400, date: now)], now: now)
        XCTAssertEqual(high.heights[5], 1)
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

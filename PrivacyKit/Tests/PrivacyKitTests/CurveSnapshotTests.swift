import Foundation
import XCTest
@testable import PrivacyKit

final class CurveSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCurvePreservesRawLowValuesAndGapsInsteadOfReusingClampedBars() {
        let state = PrivacyActivityState(readings: [
            .init(mgDL: 18, date: now), .init(mgDL: 90, date: now.addingTimeInterval(-600))
        ], now: now, meterStyle: .rangeCurve, curveReferences: .init(lower: 3.9, upper: 10, single: 6))
        XCTAssertEqual(state.effectiveCurveReadings[5] ?? -1, 1, accuracy: 0.0001)
        XCTAssertNil(state.effectiveCurveReadings[4])
        XCTAssertEqual(state.curveReferences?.single, 6)
        XCTAssertEqual(state.measuredAt, now)
        XCTAssertEqual(state.heights[5], 0.12)
    }

    func testOldSnapshotDecodesAndNewSnapshotStaysWithinActivityBudget() throws {
        let state = PrivacyActivityState(readings: [.init(mgDL: 90, date: now)], now: now,
                                         cover: Data(repeating: 1, count: 1200), meterStyle: .singleCurve)
        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        XCTAssertLessThan(data.count, 2500)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "curveReadings"); old.removeValue(forKey: "curveReferences")
        let decoded = try JSONDecoder().decode(PrivacyActivityState.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.effectiveCurveReadings[5])
        XCTAssertEqual(decoded.staleDate, now.addingTimeInterval(360))
    }
    func testClampedLegacyBarsCannotInventCurveValuesOnTheWrongSideOfAReference() throws {
        let state = PrivacyActivityState(readings: [.init(mgDL: 324, date: now)], now: now)
        let data = try JSONEncoder().encode(state)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "curveReadings")
        let decoded = try JSONDecoder().decode(PrivacyActivityState.self, from: JSONSerialization.data(withJSONObject: old))
            .replacingMeterStyle(.rangeCurve).replacingCurveReferences(.init(upper: 15))
        XCTAssertTrue(decoded.effectiveCurveReadings.allSatisfy { $0 == nil })
        XCTAssertEqual(decoded.staleDate, now.addingTimeInterval(360))
    }
}

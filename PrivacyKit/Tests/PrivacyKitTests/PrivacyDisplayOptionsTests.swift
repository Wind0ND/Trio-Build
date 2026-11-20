import Foundation
import XCTest
@testable import PrivacyKit

final class PrivacyDisplayOptionsTests: XCTestCase {
    func testReferenceUsesFiveActualReadingsEvenWhenSpacingIsIrregular() {
        let now = Date()
        let readings = (0 ..< 5).map { PrivacyReading(mgDL: Double(9 - $0) * 18, date: now - Double($0) * 180) }
        let state = PrivacyActivityState(readings: readings, now: now, meterStyle: .referenceFive)
        XCTAssertEqual(state.waveformHeights.prefix(5).compactMap { $0 }.count, 5)
        XCTAssertEqual(Array(state.waveformHeights.prefix(5)).compactMap { $0 }, [5.0/12, 6.0/12, 7.0/12, 8.0/12, 9.0/12])
    }
    func testSixDistinctPalettesShareAllSixRangesAndContinuousBoundaries() {
        XCTAssertEqual(PrivacyPalettePreset.allCases.count, 6)
        let unique = Set(PrivacyPalettePreset.allCases.map { preset in
            preset.colors.map { "\($0.red),\($0.green),\($0.blue)" }.joined(separator: ";")
        })
        XCTAssertEqual(unique.count, 6)
        for preset in PrivacyPalettePreset.allCases {
            let palette = PrivacyPalette(preset: preset)
            XCTAssertEqual(preset.colors.count, 6)
            for (index, value) in [2.0, 3.5, 5, 7, 10, 15].enumerated() {
                XCTAssertEqual(palette.color(mgDL: value * 18), preset.colors[index])
            }
            for boundary in PrivacyPalette.defaultBoundaries {
                let left = palette.color(mgDL: (boundary - 0.0001) * 18)
                let right = palette.color(mgDL: (boundary + 0.0001) * 18)
                XCTAssertLessThan(abs(left.red - right.red) + abs(left.green - right.green) + abs(left.blue - right.blue), 0.003)
            }
        }
        XCTAssertNotEqual(PrivacyPalettePreset.quiet.colors, PrivacyPalettePreset.balanced.colors)
        XCTAssertNotEqual(PrivacyPalettePreset.mist.colors, PrivacyPalettePreset.balanced.colors)
    }

    func testReferenceUsesLatestFiveAndNeverReplacesRealHistoryOrFreshness() throws {
        let now = Date()
        let readings = (0 ..< 6).map { PrivacyReading(mgDL: Double(6 - $0) * 18, date: now - Double($0) * 300) }
        let original = PrivacyActivityState(readings: readings, now: now)
        let reference = original.replacingMeterStyle(.referenceFive)
        XCTAssertEqual(reference.heights, original.heights)
        XCTAssertEqual(Array(reference.waveformHeights.prefix(5)), Array(original.heights.suffix(5)))
        XCTAssertEqual(reference.waveformHeights.last!, 5.0 / 12)
        XCTAssertEqual(reference.color, original.color)
        XCTAssertEqual(reference.measuredAt, original.measuredAt)
        XCTAssertEqual(reference.staleDate, original.staleDate)
        XCTAssertEqual(reference.replacingMeterStyle(.history), original)
        XCTAssertEqual(try JSONDecoder().decode(PrivacyActivityState.self, from: JSONEncoder().encode(reference)), reference)
    }

    func testMissingSamplesRemainMissingAndOldOrUnknownStyleFallsBack() throws {
        let state = PrivacyActivityState(readings: [], now: Date(), meterStyle: .referenceFive)
        XCTAssertEqual(state.waveformHeights.prefix(5).compactMap { $0 }.count, 0)
        XCTAssertNil(state.measuredAt)
        XCTAssertTrue(state.isStale(at: Date()))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        for style: String? in [nil, "unknown-future-style"] {
            json["meterStyle"] = style
            let decoded = try JSONDecoder().decode(PrivacyActivityState.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.waveformHeights, decoded.heights)
        }
    }
}

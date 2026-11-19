import XCTest
@testable import PrivacyKit

final class PrivacyMeterGeometryTests: XCTestCase {
    func testSixOrderedBarsFitEveryProposedWidth() {
        for presentation in [PrivacyMeterPresentation.standard, .compact, .minimal] {
            for width in [6.0, 10, 12, 14, 20, 22, 40] {
                let geometry = PrivacyMeterGeometry(
                    heights: [0.2, 0.4, 0.6, 1, 0.8, 0.5], availableWidth: width,
                    height: 16, presentation: presentation
                )
                XCTAssertEqual(geometry.bars.count, 6)
                XCTAssertLessThanOrEqual(geometry.width, width)
                var previousEnd = 0.0
                for bar in geometry.bars {
                    XCTAssertGreaterThanOrEqual(bar.x, previousEnd - 0.0001)
                    XCTAssertGreaterThan(bar.width, 0)
                    XCTAssertLessThanOrEqual(bar.x + bar.width, geometry.width + 0.0001)
                    XCTAssertGreaterThanOrEqual(bar.y, 0)
                    XCTAssertLessThanOrEqual(bar.y + bar.height, geometry.height + 0.0001)
                    XCTAssertEqual(bar.y + bar.height / 2, geometry.height / 2, accuracy: 0.0001)
                    previousEnd = bar.x + bar.width
                }
                XCTAssertEqual(geometry.bars[3].height, 16, accuracy: 0.0001)
                XCTAssertLessThan(geometry.bars[0].height, geometry.bars[1].height)
            }
        }
    }

    func testRingSharesTheMeterCenterAndFitsNarrowBounds() {
        for width in [6.0, 10, 12, 14, 20] {
            let geometry = PrivacyMeterGeometry(heights: [], availableWidth: width, height: 16, presentation: .minimal)
            XCTAssertEqual(geometry.ring.x + geometry.ring.width / 2, geometry.width / 2, accuracy: 0.0001)
            XCTAssertEqual(geometry.ring.y + geometry.ring.height / 2, geometry.height / 2, accuracy: 0.0001)
            XCTAssertEqual(geometry.ring.width, geometry.ring.height)
            XCTAssertGreaterThanOrEqual(geometry.ring.x, 0)
            XCTAssertLessThanOrEqual(geometry.ring.x + geometry.ring.width, geometry.width)
        }
    }

    func testMissingAndMalformedHeightsKeepSixFiniteSlots() {
        let geometry = PrivacyMeterGeometry(
            heights: [nil, .nan, -.infinity, -2, 4, 0.5], availableWidth: 14,
            height: 16, presentation: .minimal
        )
        XCTAssertEqual(geometry.bars.count, 6)
        for bar in geometry.bars {
            XCTAssertTrue(bar.x.isFinite && bar.y.isFinite && bar.width.isFinite && bar.height.isFinite)
            XCTAssertGreaterThan(bar.height, 0)
            XCTAssertLessThanOrEqual(bar.height, 16)
        }
        XCTAssertEqual(geometry.bars[4].height, 16)
    }
}

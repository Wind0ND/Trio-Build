import XCTest
@testable import MedtrumLifecycleKit

final class MedtrumBasalPulsePlanTests: XCTestCase {
    private let rates = (0 ... 600).map { Double($0) / 20 }

    func testNativeBudgetUsesOneMinuteAndIncludesCompanionOnlyOnce() throws {
        let plan = try XCTUnwrap(MedtrumBasalPulsePlan.make(units: 0.2, companionRate: 0.8,
            companionMinutes: 30, supportedRates: rates, maximumRate: 30))
        XCTAssertEqual(plan.minutes, 1)
        XCTAssertEqual(plan.rate, 12.8, accuracy: 0.000001)
        XCTAssertEqual(plan.extraUnits, 0.2, accuracy: 0.000001)
    }

    func testSavedLimitExtendsTransportWithoutIncreasingBudgetOrLimit() throws {
        let plan = try XCTUnwrap(MedtrumBasalPulsePlan.make(units: 0.2, companionRate: 0.8,
            companionMinutes: 30, supportedRates: rates, maximumRate: 10))
        XCTAssertEqual(plan.minutes, 2)
        XCTAssertLessThanOrEqual(plan.rate, 10)
        XCTAssertLessThanOrEqual(plan.extraUnits, 0.2 + 0.000001)
    }

    func testInvalidUnsupportedOrUnrepresentableBudgetCannotProduceAPlan() {
        for units in [Double.nan, .infinity, -1, 0, 1000] {
            XCTAssertNil(MedtrumBasalPulsePlan.make(units: units, companionRate: 0.8,
                companionMinutes: 30, supportedRates: rates, maximumRate: 30))
        }
        XCTAssertNil(MedtrumBasalPulsePlan.make(units: 0.2, companionRate: 0.8,
            companionMinutes: 30, supportedRates: [], maximumRate: 30))
        XCTAssertNil(MedtrumBasalPulsePlan.make(units: 0.2, companionRate: 0.8,
            companionMinutes: 30, supportedRates: rates, maximumRate: 0.5))
    }

    func testZeroCompanionAndRoundingNeverAddMoreThanNativeBudget() throws {
        let plan = try XCTUnwrap(MedtrumBasalPulsePlan.make(units: 0.1234, companionRate: 0,
            companionMinutes: 60, supportedRates: rates, maximumRate: 30))
        XCTAssertLessThanOrEqual(plan.extraUnits, 0.1234)
        XCTAssertGreaterThan(plan.extraUnits, 0)
        XCTAssertTrue(rates.contains(plan.rate))
    }
}

import XCTest
@testable import MedtrumLifecycleKit

final class MedtrumBasalPulsePlanTests: XCTestCase {
    func testWholePlanNormalizesNativeFractionalLowBasalBeforePulse() throws {
        let plan = try XCTUnwrap(MedtrumBasalPulsePlan.make(units: 0.2, companionRate: 0.53,
            companionMinutes: 30, supportedRates: rates, maximumRate: 30))
        XCTAssertTrue(rates.contains(plan.companionRate))
        XCTAssertLessThanOrEqual(plan.companionRate, 0.53)
        XCTAssertLessThanOrEqual(plan.extraUnits, 0.2 + 0.000001)
    }

    func testProtectiveInterruptionPermitsOnlyNonAddingRatesOrCancellation() {
        XCTAssertTrue(MedtrumBasalPulsePlan.permitsProtectiveInterruption(rate: 0, duration: 1800, scheduledRate: 0.8, pulseRate: 12))
        XCTAssertTrue(MedtrumBasalPulsePlan.permitsProtectiveInterruption(rate: 0.5, duration: 1800, scheduledRate: 0.8, pulseRate: 12))
        XCTAssertTrue(MedtrumBasalPulsePlan.permitsProtectiveInterruption(rate: 0, duration: 0, scheduledRate: 0.8, pulseRate: 12))
        XCTAssertFalse(MedtrumBasalPulsePlan.permitsProtectiveInterruption(rate: 10, duration: 1800, scheduledRate: 0.8, pulseRate: 12))
    }

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

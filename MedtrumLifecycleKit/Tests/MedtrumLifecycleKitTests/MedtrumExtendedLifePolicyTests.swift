import Foundation
@testable import MedtrumLifecycleKit
import XCTest

final class MedtrumExtendedLifePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = Data([1, 0, 0, 0])

    func testPulseStartsAtReported120HoursDespiteYoungerActivationClock() {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 432_000, sessionID: session, at: now)
        let activated = now.addingTimeInterval(-3600)
        _ = policy.evaluate(extended: true, activeSession: true, sessionID: session, activatedAt: activated, now: now)
        XCTAssertTrue(policy.isWithinPulseWindow(sessionID: session, activatedAt: activated, now: now))
    }

    func testReportedAgeBeyond144HoursOverridesYoungerActivationClockAfterRestoration() throws {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 522_000, sessionID: session, at: now)
        let restored = try JSONDecoder().decode(MedtrumExtendedLifePolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(restored.isWithinPulseWindow(sessionID: session,
            activatedAt: now.addingTimeInterval(-514_800), now: now))
    }

    func testProjected144HourClosureSurvivesRollbackAndRestartButNotReplacement() throws {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 518_399, sessionID: session, at: now)
        let activated = now.addingTimeInterval(-514_800)
        XCTAssertTrue(policy.isWithinPulseWindow(sessionID: session, activatedAt: activated, now: now))
        _ = policy.evaluate(extended: true, activeSession: true, sessionID: session, activatedAt: activated,
            now: now.addingTimeInterval(1))
        XCTAssertFalse(policy.isWithinPulseWindow(sessionID: session, activatedAt: activated, now: now.addingTimeInterval(1)))
        let restored = try JSONDecoder().decode(MedtrumExtendedLifePolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(restored.isWithinPulseWindow(sessionID: session, activatedAt: activated, now: now.addingTimeInterval(-60)))
        XCTAssertTrue(restored.isWithinPulseWindow(sessionID: Data([2, 0, 0, 0]), activatedAt: activated, now: now))
    }

    func testActivationClock144HourClosureCannotReopenOnRollback() throws {
        var policy = MedtrumExtendedLifePolicy()
        let activated = now.addingTimeInterval(-518_400)
        _ = policy.evaluate(extended: true, activeSession: true, sessionID: session, activatedAt: activated, now: now)
        let restored = try JSONDecoder().decode(MedtrumExtendedLifePolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(restored.isWithinPulseWindow(sessionID: session, activatedAt: activated, now: now.addingTimeInterval(-3600)))
    }

    func testLegacyPolicyAndForeignSessionAgeCannotInventPulseEligibility() throws {
        let legacy = try JSONDecoder().decode(MedtrumExtendedLifePolicy.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.isWithinPulseWindow(sessionID: session, activatedAt: now.addingTimeInterval(-432_000), now: now))
        XCTAssertFalse(legacy.isWithinPulseWindow(sessionID: Data(), activatedAt: now.addingTimeInterval(-432_000), now: now))
        var policy = legacy
        policy.observe(age: 600_000, sessionID: session, at: now)
        XCTAssertFalse(policy.isWithinPulseWindow(sessionID: Data([2]), activatedAt: now, now: now))
    }

    func testCrossingIsLatchedBeforeTheNextDeviceReportAndSurvivesRollback() throws {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 431_999, sessionID: session, at: now)
        XCTAssertEqual(policy.evaluate(extended: true, activeSession: true, sessionID: session, activatedAt: nil,
                                       now: now.addingTimeInterval(2)), .extendedAgeLimit)
        let restored = try JSONDecoder().decode(MedtrumExtendedLifePolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(restored.restriction(extended: true, activeSession: true, sessionID: session,
                                           activatedAt: nil, now: now), .extendedAgeLimit)
    }

    func testRepeatedEqualReportDoesNotMoveTheBoundaryLater() {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 431_999, sessionID: session, at: now)
        policy.observe(age: 431_999, sessionID: session, at: now.addingTimeInterval(5))
        XCTAssertEqual(policy.restriction(extended: true, activeSession: true, sessionID: session,
                                         activatedAt: nil, now: now.addingTimeInterval(5)), .extendedAgeLimit)
    }

    func testUnconfirmedLifetimePreferenceCannotReopenTheSameExtendedPatch() {
        var policy = MedtrumExtendedLifePolicy()
        _ = policy.evaluate(extended: true, activeSession: true, sessionID: session,
                            activatedAt: now.addingTimeInterval(-500_000), now: now)
        XCTAssertEqual(policy.restriction(extended: false, activeSession: true, sessionID: session,
                                         activatedAt: now.addingTimeInterval(-500_000), now: now), .extendedAgeLimit)
        XCTAssertEqual(policy.restriction(extended: false, activeSession: true, sessionID: Data([2]),
                                         activatedAt: now, now: now), .none)
    }

    func testExtendedSessionChangesAtExactly120Hours() {
        let policy = MedtrumExtendedLifePolicy()
        for (age, expected) in [(431_999.0, false), (432_000.0, true), (432_001.0, true), (800_000.0, true)] {
            XCTAssertEqual(policy.restriction(
                extended: true, activeSession: true, sessionID: session,
                activatedAt: now.addingTimeInterval(-age), now: now
            ) == .extendedAgeLimit, expected)
        }
    }

    func testNormalLifetimeDoesNotAcquireAnExtendedModeRestriction() {
        XCTAssertEqual(MedtrumExtendedLifePolicy().restriction(
            extended: false, activeSession: true, sessionID: session,
            activatedAt: now.addingTimeInterval(-800_000), now: now
        ), .none)
    }

    func testUnknownAndFutureActivationDoNotPermitAutomaticBolusInExtendedMode() {
        for activation in [nil, now.addingTimeInterval(100)] {
            XCTAssertEqual(MedtrumExtendedLifePolicy().restriction(
                extended: true, activeSession: true, sessionID: session, activatedAt: activation, now: now
            ), .ageUnknown)
        }
    }

    func testReportedAgeOverridesAYoungerDisplayClockAndSurvivesRestart() throws {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 432_000, sessionID: session, at: now)
        let restored = try JSONDecoder().decode(MedtrumExtendedLifePolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(restored.restriction(
            extended: true, activeSession: true, sessionID: session,
            activatedAt: now.addingTimeInterval(-60), now: now.addingTimeInterval(-3600)
        ), .extendedAgeLimit)
    }

    func testElapsedTimeAfterAReportClosesTheBoundary() {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 431_999, sessionID: session, at: now)
        XCTAssertEqual(policy.restriction(
            extended: true, activeSession: true, sessionID: session, activatedAt: nil,
            now: now.addingTimeInterval(1)
        ), .extendedAgeLimit)
    }

    func testNewSessionDoesNotInheritThePreviousPatchAge() {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 500_000, sessionID: session, at: now)
        XCTAssertEqual(policy.restriction(
            extended: true, activeSession: true, sessionID: Data([2, 0, 0, 0]),
            activatedAt: now, now: now
        ), .none)
    }

    func testAnOlderReportCannotReenableAnExpiredSession() {
        var policy = MedtrumExtendedLifePolicy()
        policy.observe(age: 432_001, sessionID: session, at: now)
        policy.observe(age: 30, sessionID: session, at: now.addingTimeInterval(1))
        XCTAssertEqual(policy.restriction(
            extended: true, activeSession: true, sessionID: session, activatedAt: nil, now: now
        ), .extendedAgeLimit)
    }

    func testInvalidReportsAreIgnored() {
        var policy = MedtrumExtendedLifePolicy()
        for age in [Double.nan, .infinity, -1] { policy.observe(age: age, sessionID: session, at: now) }
        XCTAssertEqual(policy.restriction(
            extended: true, activeSession: true, sessionID: session, activatedAt: now, now: now
        ), .none)
    }

    func testEndedSessionCannotIssueAnAutomaticBolus() {
        XCTAssertEqual(MedtrumExtendedLifePolicy().restriction(
            extended: false, activeSession: false, sessionID: session, activatedAt: now, now: now
        ), .noActiveSession)
    }
}

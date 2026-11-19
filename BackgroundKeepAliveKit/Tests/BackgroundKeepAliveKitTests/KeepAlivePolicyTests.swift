import Foundation
import XCTest
@testable import BackgroundKeepAliveKit

final class KeepAlivePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testAutomaticProtectionStartsBeforeTheAppCanBeSuspended() {
        var policy = KeepAlivePolicy()
        policy.beginMonitoring(at: now)
        policy.accept(now, now: now)
        let config = KeepAlivePolicy.Configuration(mode: "smart", stallMinutes: 5, maxSessionMinutes: 15)
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now + 1, background: true, blocked: false, capped: false))
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 1, background: false, blocked: false, capped: false))
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 301, background: true, blocked: true, capped: false))
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 301, background: true, blocked: false, capped: true))
    }

    func testNewerBackfillDoesNotCountAsRecovery() {
        var policy = KeepAlivePolicy()
        XCTAssertTrue(policy.accept(now - 900, now: now))
        XCTAssertTrue(policy.isStale(now: now, interval: 600))
        XCTAssertTrue(policy.accept(now - 700, now: now))
        XCTAssertTrue(policy.isStale(now: now, interval: 600))
        XCTAssertTrue(policy.accept(now - 120, now: now))
        XCTAssertFalse(policy.isStale(now: now, interval: 600))
    }

    func testFutureAndRegressingTimestampsDoNotMoveDeadline() {
        var policy = KeepAlivePolicy()
        XCTAssertTrue(policy.accept(now - 120, now: now))
        XCTAssertFalse(policy.accept(now + 30, now: now))
        XCTAssertFalse(policy.accept(now - 120, now: now))
        XCTAssertFalse(policy.accept(now - 900, now: now))
        XCTAssertEqual(policy.deadline(interval: 600), now + 480)
    }

    func testThresholdAndAbsentSample() {
        var policy = KeepAlivePolicy()
        XCTAssertNil(policy.deadline(interval: 600))
        XCTAssertFalse(policy.isStale(now: now, interval: 600))
        XCTAssertTrue(policy.accept(now - 600, now: now))
        XCTAssertTrue(policy.isStale(now: now, interval: 600))
    }

    func testMonitoringWithoutFirstSampleHasStableDeadline() {
        var policy = KeepAlivePolicy()
        policy.beginMonitoring(at: now)
        policy.beginMonitoring(at: now + 120)
        XCTAssertEqual(policy.deadline(interval: 600), now + 600)
        XCTAssertTrue(policy.isStale(now: now + 600, interval: 600))
        XCTAssertTrue(policy.accept(now + 630, now: now + 630))
        XCTAssertEqual(policy.deadline(interval: 600), now + 1230)
    }

    func testConfigurationUsesDefaultsAndClampsBeforeConvertingToSeconds() {
        let defaults = KeepAlivePolicy.Configuration(mode: nil, stallMinutes: 0, maxSessionMinutes: 0)
        XCTAssertEqual(defaults.mode, .smart)
        XCTAssertEqual(defaults.stallInterval, 600)
        XCTAssertEqual(defaults.capInterval, 2700)
        let limits = KeepAlivePolicy.Configuration(mode: "always", stallMinutes: Int.max, maxSessionMinutes: -1)
        XCTAssertEqual(limits.mode, .always)
        XCTAssertEqual(limits.stallInterval, 3600)
        XCTAssertEqual(limits.capInterval, 900)
    }
}

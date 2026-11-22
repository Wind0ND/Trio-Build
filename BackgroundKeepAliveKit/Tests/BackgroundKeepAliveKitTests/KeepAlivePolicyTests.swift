import Foundation
import XCTest
@testable import BackgroundKeepAliveKit

final class KeepAlivePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testForegroundRecoversMissingInterruptionEndAndRespectsOtherAudio() {
        var interruption = KeepAliveInterruptionState()
        interruption.began()
        interruption.foreground(otherAudio: true)
        XCTAssertTrue(interruption.blocked)
        interruption.wake(otherAudio: false)
        XCTAssertFalse(interruption.blocked)
        interruption.began()
        interruption.foreground(otherAudio: false)
        XCTAssertFalse(interruption.blocked)
    }

    func testOutageDueDuringSnoozeKeepsItsDeadlineAndIsDeliveredAtSnoozeEnd() {
        let deadline = now.addingTimeInterval(360)
        let snoozeEnd = now.addingTimeInterval(900)
        XCTAssertEqual(KeepAliveReminderPolicy.fireDate(deadline: deadline, snoozeUntil: snoozeEnd), snoozeEnd)
        XCTAssertEqual(KeepAliveReminderPolicy.fireDate(deadline: deadline, snoozeUntil: now), deadline)
        XCTAssertEqual(KeepAliveReminderPolicy.fireDate(deadline: deadline, snoozeUntil: nil), deadline)
    }

    func testAnActiveInterruptionCannotBeClearedByADataWake() {
        var interruption = KeepAliveInterruptionState()
        interruption.began()
        interruption.wake(otherAudio: false)
        XCTAssertTrue(interruption.blocked)
        interruption.ended(shouldResume: false, otherAudio: true)
        XCTAssertTrue(interruption.blocked)
        interruption.wake(otherAudio: false)
        XCTAssertFalse(interruption.blocked)
    }

    func testPrivacyChangeCannotRepeatAnAcknowledgedOutageSound() {
        XCTAssertFalse(KeepAliveReminderPolicy.shouldNotify(deadline: now - 1, now: now, acknowledged: now - 1, privacyChanged: true))
        XCTAssertTrue(KeepAliveReminderPolicy.shouldNotify(deadline: now + 60, now: now, acknowledged: now - 1, privacyChanged: true))
        XCTAssertTrue(KeepAliveReminderPolicy.shouldNotify(deadline: now - 1, now: now, acknowledged: nil, privacyChanged: false))
    }

    func testAutomaticAudioOnlyRunsAfterSixMinutesAndStopsAsSoonAsDataRecovers() {
        var policy = KeepAlivePolicy()
        policy.beginMonitoring(at: now)
        policy.accept(now, now: now)
        let config = KeepAlivePolicy.Configuration(mode: "smart", stallMinutes: 5, maxSessionMinutes: 15)
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 1, background: true, blocked: false, capped: false))
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 359, background: true, blocked: false, capped: false))
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now + 360, background: true, blocked: false, capped: false))
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now + 7200, background: true, blocked: false, capped: true))
        policy.accept(now + 7200, now: now + 7200)
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 7201, background: true, blocked: false, capped: false))
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
        XCTAssertEqual(defaults.stallInterval, 360)
        let limits = KeepAlivePolicy.Configuration(mode: "always", stallMinutes: Int.max, maxSessionMinutes: -1)
        XCTAssertEqual(limits.mode, .always)
        XCTAssertEqual(limits.stallInterval, 360)
    }

    func testPeriodicDefaultWindowHasFiveMinutesOnAndTwentyFiveOff() {
        var policy = KeepAlivePolicy()
        policy.beginMonitoring(at: now)
        let config = KeepAlivePolicy.Configuration(mode: "periodic", stallMinutes: 5, maxSessionMinutes: 15)
        XCTAssertEqual(config.mode.rawValue, "periodic")
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now, background: true, blocked: false, capped: false))
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now + 299, background: true, blocked: false, capped: false))
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 300, background: true, blocked: false, capped: false))
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now + 1799, background: true, blocked: false, capped: false))
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now + 1800, background: true, blocked: false, capped: false))
    }

    func testHealthyFiveMinuteSamplesNeverReachTheNotificationDeadline() {
        var policy = KeepAlivePolicy()
        let config = KeepAlivePolicy.Configuration(mode: "smart", stallMinutes: 5, maxSessionMinutes: 15)
        for cycle in 0 ..< 12 {
            let sample = now + Double(cycle) * 300
            policy.accept(sample, now: sample)
            XCTAssertFalse(policy.isStale(now: sample + 315, interval: config.stallInterval))
        }
    }

    func testPeriodicUsesMonotonicUptimeAndDoesNotExtendAWindowOnEverySample() {
        var policy = KeepAlivePolicy()
        policy.beginMonitoring(at: now)
        policy.backgroundChanged(true, uptime: 100)
        let config = KeepAlivePolicy.Configuration(mode: "periodic", cycleMinutes: 30, audioMinutes: 5)
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now + 99999, background: true, blocked: false, uptime: 399))
        policy.accept(now + 1, now: now + 1)
        XCTAssertFalse(policy.wantsAudio(configuration: config, now: now - 99999, background: true, blocked: false, uptime: 400))
        XCTAssertTrue(policy.wantsAudio(configuration: config, now: now, background: true, blocked: false, uptime: 1900))
        let bounded = KeepAlivePolicy.Configuration(mode: "periodic", cycleMinutes: 5, audioMinutes: Int.max)
        XCTAssertEqual(bounded.audioInterval, 240)
        XCTAssertLessThan(bounded.audioInterval, bounded.cycleInterval)
    }

    func testRefreshIsBoundedToOneRequestPerMinute() {
        var policy = KeepAlivePolicy()
        XCTAssertTrue(policy.reserveRefresh(now: now))
        XCTAssertFalse(policy.reserveRefresh(now: now + 1))
        XCTAssertFalse(policy.reserveRefresh(now: now + 59))
        XCTAssertTrue(policy.reserveRefresh(now: now + 60))
        XCTAssertTrue(policy.reserveRefresh(now: now - 30))
    }

    func testDisabledBlockedAndContinuousModesHaveExplicitSemantics() {
        let policy = KeepAlivePolicy()
        let off = KeepAlivePolicy.Configuration(mode: "off", stallMinutes: 5, maxSessionMinutes: 15)
        let always = KeepAlivePolicy.Configuration(mode: "always", stallMinutes: 5, maxSessionMinutes: 15)
        XCTAssertFalse(policy.wantsAudio(configuration: off, now: now, background: true, blocked: false, capped: false))
        XCTAssertTrue(policy.wantsAudio(configuration: always, now: now, background: true, blocked: false, capped: true))
        XCTAssertFalse(policy.wantsAudio(configuration: always, now: now, background: true, blocked: true, capped: false))
    }
}

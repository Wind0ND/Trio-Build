import XCTest
@testable import BackgroundKeepAliveKit

final class RecoveryReviewTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testSourceSwitchAndOldCallbacksCannotAdvanceFreshness() {
        var state = SourceFreshness()
        state.select("simulator")
        XCTAssertTrue(state.accept(now, sourceID: "simulator", now: now))
        state.select("real")
        XCTAssertNil(state.latest(now: now))
        XCTAssertFalse(state.accept(now, sourceID: "simulator", now: now))
        XCTAssertNil(state.latest(now: now))
        XCTAssertTrue(state.accept(now, sourceID: "real", now: now))
    }
    func testFutureAndClockRollbackCannotHideEarlierValidSample() throws {
        var state = SourceFreshness()
        state.select("real")
        XCTAssertFalse(state.accept(now + 100, sourceID: "real", now: now))
        XCTAssertTrue(state.accept(now - 60, sourceID: "real", now: now))
        XCTAssertEqual(state.latest(now: now), now - 60)
        let restored = try JSONDecoder().decode(SourceFreshness.self, from: JSONEncoder().encode(state))
        XCTAssertNil(restored.latest(now: now - 120))
    }
    func testMissedPeriodicWindowsAreCountedWithoutCatchupAudio() {
        var state = PeriodicAudioWindows()
        XCTAssertEqual(state.observe(elapsed: 0, cycle: 1800, on: 300, started: true), 0)
        XCTAssertEqual(state.observe(elapsed: 3601, cycle: 1800, on: 300, started: false), 1)
        XCTAssertEqual(state.observe(elapsed: 5700, cycle: 1800, on: 300, started: false), 1)
        XCTAssertEqual(state.observe(elapsed: 9300, cycle: 1800, on: 300, started: false), 2)
        XCTAssertEqual(state.observe(elapsed: 9300, cycle: 1800, on: 300, started: false), 0)
    }
    func testAcknowledgedOutageSurvivesAdvancingStaleBackfillAndRestart() {
        XCTAssertFalse(KeepAliveReminderPolicy.shouldNotify(deadline: now - 60, now: now,
            acknowledged: now - 120, privacyChanged: false))
        XCTAssertTrue(KeepAliveReminderPolicy.shouldNotify(deadline: now + 300, now: now,
            acknowledged: now - 120, privacyChanged: false))
    }
}

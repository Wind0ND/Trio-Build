import Foundation
import XCTest
@testable import PrivacyKit

final class CurveAndLifecycleTests: XCTestCase {
    func testReferencesAreDisplayCoordinatesAndDoNotClipCrossings() {
        let geometry = PrivacyCurveGeometry(values: [3.6, 5.8, 10.7, 8.2, 4.4, 6.2], width: 100, height: 120,
                                            references: .init(), dual: true)
        XCTAssertEqual(geometry.referenceY.count, 2)
        XCTAssertEqual(geometry.referenceY.first ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(geometry.referenceY.last ?? -1, 20, accuracy: 0.001)
        XCTAssertTrue(geometry.segments.contains { $0.start.y > 80 })
        XCTAssertTrue(geometry.segments.contains { $0.end.y < 20 })
    }

    func testAdjustableSingleLineAndExtendedRangeUseStableScale() {
        let config = PrivacyCurveReferences(lower: 3.9, upper: 15, single: 6)
        let single = PrivacyCurveGeometry(values: [4, 6, 8], width: 100, height: 120, references: config, dual: false)
        XCTAssertEqual(single.referenceY.first ?? -1, 60, accuracy: 0.001)
        let dual = PrivacyCurveGeometry(values: [4, 6, 8], width: 100, height: 120, references: config, dual: true)
        XCTAssertTrue(dual.referenceY.allSatisfy { $0 >= 0 && $0 <= 120 })
        XCTAssertEqual(dual.segments.last?.end.y ?? -1, 120 * (1 - 8 / 16.5), accuracy: 0.001)
    }

    func testInvalidReferenceConfigurationCannotProduceInvalidGeometry() {
        let config = PrivacyCurveReferences(lower: .nan, upper: -1, single: .infinity)
        let geometry = PrivacyCurveGeometry(values: [4, 5, 6], width: .infinity, height: .nan, references: config, dual: true)
        XCTAssertEqual(config.lower, 4)
        XCTAssertEqual(config.upper, 10)
        XCTAssertEqual(config.single, 5)
        XCTAssertTrue(geometry.referenceY.allSatisfy(\.isFinite))
        XCTAssertEqual(PrivacyCurveReferences(lower: 12, upper: 4, single: 7).upper, 10)
    }

    func testMissingReadingsNeverBecomeConnectingSegmentsOrOvershootPeaks() {
        let geometry = PrivacyCurveGeometry(values: [4, 8, nil, 5, 7, 6], width: 100, height: 120,
                                            references: .init(), dual: false)
        XCTAssertEqual(geometry.segments.count, 3)
        XCTAssertFalse(geometry.segments.contains { $0.start.x < 40 && $0.end.x > 40 })
        for segment in geometry.segments {
            let bounds = min(segment.start.y, segment.end.y) ... max(segment.start.y, segment.end.y)
            XCTAssertTrue(bounds.contains(segment.control1.y))
            XCTAssertTrue(bounds.contains(segment.control2.y))
        }
    }

    func testEndedBackgroundActivityWaitsInsteadOfReceivingUpdates() {
        XCTAssertEqual(ActivityLifecyclePolicy.action(state: .ended, foreground: false, enabled: true), .waitForForeground)
        XCTAssertEqual(ActivityLifecyclePolicy.action(state: .dismissed, foreground: true, enabled: true), .create)
        XCTAssertEqual(ActivityLifecyclePolicy.action(state: .active, foreground: true, enabled: false), .end)
        XCTAssertEqual(ActivityLifecyclePolicy.action(state: .stale, foreground: false, enabled: true), .update)
    }

    @MainActor func testPublicationAwaitCannotLetAnotherLifecycleOperationEnter() async {
        let queue = ActivityPublicationQueue()
        let gate = SuspensionGate()
        var trace: [String] = []
        let first = Task { await queue.run { trace.append("begin"); await gate.wait(); trace.append("end") } }
        await gate.waitUntilEntered()
        let second = Task { await queue.run { trace.append("next") } }
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(trace, ["begin"])
        gate.release()
        await first.value
        await second.value
        XCTAssertEqual(trace, ["begin", "end", "next"])
    }
}

@MainActor private final class SuspensionGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func wait() async { await withCheckedContinuation { waiting = $0; didEnter = true; entered?.resume(); entered = nil } }
    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }
}

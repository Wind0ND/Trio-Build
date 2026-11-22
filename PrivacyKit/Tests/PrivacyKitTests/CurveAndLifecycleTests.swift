import Foundation
import XCTest
@testable import PrivacyKit

final class CurveAndLifecycleTests: XCTestCase {
    func testReferencesAndSamplesShareTheCoverCoordinateSystem() {
        for (height, cover) in [(22.0, 20.0), (30, 24), (16, 12)] {
            let middle = height / 2
            let top = middle - cover / 2
            let bottom = middle + cover / 2
            let references = PrivacyCurveReferences(lower: 3.9, upper: 15, single: 7)
            let dual = PrivacyCurveGeometry(values: [3, 3.9, 15, 16], width: 20,
                height: height, coverHeight: cover, references: references, dual: true)
            XCTAssertEqual(dual.referenceY, [bottom, top])
            XCTAssertEqual(dual.segments[0].end.y, bottom, accuracy: 0.001)
            XCTAssertEqual(dual.segments[1].end.y, top, accuracy: 0.001)
            XCTAssertGreaterThan(dual.segments[0].start.y, bottom)
            XCTAssertLessThan(dual.segments[2].end.y, top)
            for value in [5.0, 7, 12] {
                let single = PrivacyCurveGeometry(values: [value - 1, value, value + 1], width: 20,
                    height: height, coverHeight: cover, references: .init(single: value), dual: false)
                XCTAssertEqual(single.referenceY, [middle])
                XCTAssertEqual(single.segments[0].end.y, middle, accuracy: 0.001)
                XCTAssertGreaterThan(single.segments[0].start.y, middle)
                XCTAssertLessThan(single.segments[1].end.y, middle)
            }
        }
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

    func testSuccessorUsesOriginalSessionStartAcrossProcessRelaunch() {
        let start = Date(timeIntervalSince1970: 1000)
        let deadline = start.addingTimeInterval(8 * 3600)
        XCTAssertEqual(ActivityLifecyclePolicy.successorDate(start: start,
            now: start.addingTimeInterval(6 * 3600)), deadline)
        XCTAssertNil(ActivityLifecyclePolicy.successorDate(start: start, now: deadline))
        XCTAssertFalse(ActivityLifecyclePolicy.shouldRenew(start: start, now: start, foreground: true))
        XCTAssertFalse(ActivityLifecyclePolicy.shouldRenew(start: start, now: deadline, foreground: false))
        XCTAssertTrue(ActivityLifecyclePolicy.shouldRenew(start: start, now: deadline, foreground: true))
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

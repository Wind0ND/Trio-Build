import Foundation
import XCTest

@testable import AiDEXKit

final class AiDEXDiagnosticEventTests: XCTestCase {
    func testNotificationCarriesOnlyBoundedAllowlistedFields() {
        let expectation = expectation(description: "diagnostic notification")
        var userInfo: [AnyHashable: Any]?
        let token = NotificationCenter.default.addObserver(
            forName: AiDEXDiagnosticEvent.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            userInfo = notification.userInfo
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        AiDEXDiagnosticEvent.record(.scan, .started, count: 100_000)
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(
            Set(userInfo?.keys.compactMap { $0 as? String } ?? []),
            Set(["count", "feature", "outcome", "schema", "stage"])
        )
        XCTAssertEqual(userInfo?["schema"] as? Int, 1)
        XCTAssertEqual(userInfo?["feature"] as? String, "aidex")
        XCTAssertEqual(userInfo?["stage"] as? String, "scan")
        XCTAssertEqual(userInfo?["outcome"] as? String, "started")
        XCTAssertEqual(userInfo?["count"] as? Int, 9_999)
    }

    func testOnlyTheSmallFiniteSetsAreExposed() {
        XCTAssertEqual(
            Set(AiDEXDiagnosticEvent.Stage.allCases.map(\.rawValue)),
            Set(["match", "reading", "scan"])
        )
        XCTAssertEqual(
            Set(AiDEXDiagnosticEvent.Outcome.allCases.map(\.rawValue)),
            Set([
                "absent",
                "cancelled",
                "checksum_mismatch",
                "matched",
                "not_matched",
                "present",
                "reading_unavailable",
                "started",
                "unavailable",
                "unsupported_frame"
            ])
        )
    }

    func testMeasurementIssuesMapToTheirFiniteDiagnosticOutcomes() {
        XCTAssertEqual(
            AiDEXMeasurementIssue.unsupportedManufacturerFrame.diagnosticOutcome,
            .unsupportedFrame
        )
        XCTAssertEqual(AiDEXMeasurementIssue.checksumMismatch.diagnosticOutcome, .checksumMismatch)
        XCTAssertEqual(
            AiDEXMeasurementIssue.readingUnavailable.diagnosticOutcome,
            .readingUnavailable
        )
    }
}

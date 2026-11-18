import Foundation

/// Source-side allowlist for AiDEX's contributions to Trio's existing
/// `com.trio.diagnostics.event` export. The payload contains only the schema,
/// feature and enumerated stage/outcome plus an optional bounded count. It can
/// never carry a serial, a UUID, glucose, a packet or a raw error.
public enum AiDEXDiagnosticEvent {
    public static let notificationName = Notification.Name("com.trio.diagnostics.event")
    public static let schemaVersion = 1
    public static let feature = "aidex"

    public enum Stage: String, CaseIterable, Sendable {
        case scan
        case match
        case reading
    }

    public enum Outcome: String, CaseIterable, Sendable {
        case started
        case unavailable
        case cancelled
        case matched
        case notMatched = "not_matched"
        case absent
        case present
        case unsupportedFrame = "unsupported_frame"
        case checksumMismatch = "checksum_mismatch"
        case readingUnavailable = "reading_unavailable"
    }

    public static func record(
        _ stage: Stage,
        _ outcome: Outcome,
        count: Int? = nil
    ) {
        var userInfo: [String: Any] = [
            "schema": schemaVersion,
            "feature": feature,
            "stage": stage.rawValue,
            "outcome": outcome.rawValue
        ]
        if let count {
            userInfo["count"] = min(max(count, 0), 9_999)
        }
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
    }
}

extension AiDEXMeasurementIssue {
    var diagnosticOutcome: AiDEXDiagnosticEvent.Outcome {
        switch self {
        case .unsupportedManufacturerFrame:
            return .unsupportedFrame
        case .checksumMismatch:
            return .checksumMismatch
        case .readingUnavailable:
            return .readingUnavailable
        }
    }
}

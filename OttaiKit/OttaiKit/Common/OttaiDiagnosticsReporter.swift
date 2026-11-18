//
//  OttaiDiagnosticsReporter.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Source-side allowlist for the events Ottai contributes to Trio's diagnostic
/// export. Nothing outside these cases can be emitted, so a feature cannot leak
/// raw errors, MACs, serials or glucose into the diagnostic file by accident.
///
/// This is the common event contract: a future plugin can post the same
/// notification with its own registered feature name and needs no export code.
/// Trio's recorder validates feature/stage/outcome again before persisting.
public enum OttaiDiagnosticEvent {
    /// Must match `DiagnosticEventContract.notificationName` in Trio.
    public static let notificationName = Notification.Name("com.trio.diagnostics.event")
    public static let schemaVersion = 1
    public static let feature = "ottai"

    public enum Stage: String, Sendable {
        case nfc
        case bleMatch = "ble_match"
        case bleNonMatch = "ble_non_match"
        case activation
        case binding
        case completion
        case firstReading = "first_reading"
    }

    public enum Outcome: String, Sendable {
        case started
        case succeeded
        case tagDetected = "tag_detected"
        case failed
        case cancelled
        case unavailable
        case matched
        case notMatched = "not_matched"
        case present
        case absent
        case retried
    }

    public static func record(
        _ stage: Stage,
        _ outcome: Outcome,
        attempt: Int? = nil,
        count: Int? = nil
    ) {
        var userInfo: [String: Any] = [
            "schema": schemaVersion,
            "feature": feature,
            "stage": stage.rawValue,
            "outcome": outcome.rawValue
        ]
        // Bounded counters only; never free-form text.
        if let attempt { userInfo["attempt"] = min(max(attempt, 0), 999) }
        if let count { userInfo["count"] = min(max(count, 0), 9999) }
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
    }
}

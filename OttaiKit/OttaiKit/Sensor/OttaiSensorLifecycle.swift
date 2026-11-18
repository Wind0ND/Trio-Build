//
//  OttaiSensorLifecycle.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Local override for the rated wear window.
///
/// `activeDuration` comes from the cloud (`activeExpireTime`), which is only
/// what the account plan rates the sensor at - the firmware keeps streaming
/// past it. Both the official app and we enforce that number client-side, so
/// raising the extra-days preference extends every wear-window decision
/// without touching the cloud record or the sensor itself.
public enum OttaiWearExtension {
    /// Days added on top of the cloud-rated wear window. 0 (default) = off.
    public static let defaultsKey = "ottaiExtraWearDays"

    public static var extraSeconds: TimeInterval {
        let days = UserDefaults.standard.integer(forKey: defaultsKey)
        return days > 0 ? TimeInterval(days) * 86_400 : 0
    }

    public static func extendedWear(_ wear: TimeInterval) -> TimeInterval {
        wear + extraSeconds
    }
}

public enum OttaiSensorLifecycle: Equatable {
    case noSensor
    case warmup(progress: Double, remaining: TimeInterval)
    case active(remaining: TimeInterval, total: TimeInterval)
    case expired
    case signalLost(since: Date)
    /// The sensor's own cmd characteristic reported itself dead (state >= 4);
    /// replace the sensor.
    case failed
    /// The sensor's own cmd characteristic reports itself unactivated (state < 3)
    /// while we hold an activation record for it — its lifecycle state doesn't
    /// match what we expect, so nothing it reports can be trusted for dosing.
    case unactivated

    static let signalLostThreshold: TimeInterval = 6 * 60

    /// How recently a reading must have arrived before we treat the sensor as
    /// demonstrably still running.
    static let liveReadingWindow: TimeInterval = 15 * 60

    /// Seconds since activation. Comes from the sensor's own elapsed-seconds
    /// field wherever it is available, with the phone clock spanning only the
    /// silence since that record arrived.
    public static func age(
        activatedAt: Date?,
        sensorAge: (elapsed: TimeInterval, at: Date)?,
        now: Date = Date()
    ) -> TimeInterval? {
        let wallAge = activatedAt.map { now.timeIntervalSince($0) }
        if let sensorAge {
            let fromSensor = sensorAge.elapsed + now.timeIntervalSince(sensorAge.at)
            // The sensor's elapsed field is the more accurate clock, but a
            // reconnect can hand back a counter from a different base: a
            // firmware restart, or a history batch stamped before activation.
            // Trust it only while it agrees with the activation record from the
            // cloud; a counter that is hours off is garbage and must never turn
            // a live sensor into an expired one.
            guard let wallAge else { return fromSensor }
            return abs(fromSensor - wallAge) <= Self.sensorClockTolerance ? fromSensor : wallAge
        }
        return wallAge
    }

    /// How far the sensor's own elapsed field may drift from the activation
    /// record before we stop trusting it.
    static let sensorClockTolerance: TimeInterval = 6 * 3600

    /// Faults take precedence: the sensor's cmd-characteristic state reports
    /// failed/unactivated, and the client-side plausibility guard is equally
    /// terminal. Timestamp math only runs when there is no fault, because
    /// cmd's "activated" state (3) does not distinguish warmup from active.
    public static func compute(
        sensorPaired: Bool,
        activatedAt: Date?,
        sensorAge: (elapsed: TimeInterval, at: Date)? = nil,
        latestReadingAt: Date?,
        hasLiveMonitor: Bool,
        reportedFault: OttaiSensorFault.Kind? = nil,
        activeDuration: TimeInterval? = nil,
        preheatDuration: TimeInterval? = nil,
        now: Date = Date()
    ) -> OttaiSensorLifecycle {
        guard sensorPaired else { return .noSensor }
        switch reportedFault {
        case .signalImplausible: return .failed
        case .deviceStateUnactivated: return .unactivated
        case .deviceStateObsolete: // generic state for "not working"
            if let activatedAt, let wear = activeDuration.map(OttaiWearExtension.extendedWear),
               let age = Self.age(activatedAt: activatedAt, sensorAge: sensorAge, now: now),
               age >= wear // beyond expiration date
            {
                break
            }
            return .failed
        case .errorInfo,
             nil: break
        }
        // `activatedAt`/`activeDuration`/`preheatDuration` all come from the same
        // server-fetched DeviceInfo record — a bound sensor's record
        // always returns real durations, so they're present or absent together. No
        // placeholder default: a missing duration means the lifecycle isn't known
        // yet, not that a generic 14-day/30-min guess applies.
        guard let activatedAt, let wear = activeDuration.map(OttaiWearExtension.extendedWear),
              let warmup = preheatDuration else {
            return .noSensor
        }
        let age = Self.age(activatedAt: activatedAt, sensorAge: sensorAge, now: now) ?? 0
        // Expiry is a wall-clock claim, and a sensor that is still handing over
        // readings is by definition not finished. A drifted clock or a wear
        // window that disagrees with the cloud must never paint a live sensor as
        // expired, because that stops dosing and tells the user to rip it off.
        let liveReading = latestReadingAt.map { now.timeIntervalSince($0) <= Self.liveReadingWindow } ?? false
        if age >= wear, !liveReading { return .expired }
        if age >= wear, liveReading { return .active(remaining: 0, total: wear) }
        if age < warmup {
            return .warmup(progress: age / warmup, remaining: warmup - age)
        }
        let stale = latestReadingAt.map { abs(now.timeIntervalSince($0)) > signalLostThreshold } ?? !hasLiveMonitor
        if stale { return .signalLost(since: latestReadingAt ?? activatedAt) }
        return .active(remaining: wear - age, total: wear)
    }

    public var needsEnding: Bool {
        self == .failed
    }

    public var displayName: String {
        switch self {
        case .noSensor: return LocalizedString("No sensor", comment: "Ottai lifecycle: none")
        case .warmup: return LocalizedString("Warming up", comment: "Ottai lifecycle: warming up")
        case .active: return LocalizedString("Active", comment: "Ottai lifecycle: active")
        case .expired: return LocalizedString("Expired", comment: "Ottai lifecycle: expired")
        case .signalLost: return LocalizedString("Signal loss", comment: "Ottai lifecycle: signal loss")
        case .failed: return LocalizedString("Sensor failed", comment: "Ottai lifecycle: failed")
        case .unactivated: return LocalizedString("Sensor uninitialized", comment: "Ottai lifecycle: unactivated")
        }
    }

    public static func faultStatusDetail(for kind: OttaiSensorFault.Kind) -> String {
        switch kind {
        case .deviceStateObsolete:
            return LocalizedString("Sensor malfunction, replace sensor", comment: "Status: sensor obsolete/dead")
        case .deviceStateUnactivated:
            return LocalizedString("Sensor uninitialized, is it activated?", comment: "Status: sensor reports itself unactivated")
        case .signalImplausible:
            return LocalizedString(
                "Sensor readings implausible, consider replacing sensor",
                comment: "Status: sensor is reporting implausable readings"
            )
        case .errorInfo:
            return LocalizedString("Sensor malfunction", comment: "Status: unspecified sensor fault")
        }
    }
}

extension Bundle {
    static var ottaiKit: Bundle { Bundle(for: OttaiCGMManager.self) }
}

func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    let bundle = Bundle.ottaiKit
    if let value = value {
        return NSLocalizedString(key, tableName: tableName, bundle: bundle, value: value, comment: comment)
    }
    return NSLocalizedString(key, tableName: tableName, bundle: bundle, comment: comment)
}

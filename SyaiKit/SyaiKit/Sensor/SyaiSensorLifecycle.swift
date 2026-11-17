//
//  SyaiSensorLifecycle.swift
//  SyaiKit
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
public enum SyaiWearExtension {
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

public enum SyaiSensorLifecycle: Equatable {
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
        reportedFault: SyaiSensorFault.Kind? = nil,
        activeDuration: TimeInterval? = nil,
        preheatDuration: TimeInterval? = nil,
        now: Date = Date()
    ) -> SyaiSensorLifecycle {
        guard sensorPaired else { return .noSensor }
        switch reportedFault {
        case .signalImplausible: return .failed
        case .deviceStateUnactivated: return .unactivated
        case .deviceStateObsolete: // generic state for "not working"
            if let activatedAt, let wear = activeDuration.map(SyaiWearExtension.extendedWear),
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
        guard let activatedAt, let wear = activeDuration.map(SyaiWearExtension.extendedWear),
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
        case .noSensor: return LocalizedString("No sensor", comment: "Syai lifecycle: none")
        case .warmup: return LocalizedString("Warming up", comment: "Syai lifecycle: warming up")
        case .active: return LocalizedString("Active", comment: "Syai lifecycle: active")
        case .expired: return LocalizedString("Expired", comment: "Syai lifecycle: expired")
        case .signalLost: return LocalizedString("Signal loss", comment: "Syai lifecycle: signal loss")
        case .failed: return LocalizedString("Sensor failed", comment: "Syai lifecycle: failed")
        case .unactivated: return LocalizedString("Sensor uninitialized", comment: "Syai lifecycle: unactivated")
        }
    }

    public static func faultStatusDetail(for kind: SyaiSensorFault.Kind) -> String {
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

/// Chinese copy for the strings this target owns. The app catalogue in Trio
/// only covers the UI target; texts SyaiKit resolves through its own bundle
/// (lifecycle states, alerts, adoption errors) never pass through it.
enum SyaiLocalization {
    static var prefersChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static let chinese: [String: String] = [
        "Activating sensor": "正在激活传感器",
        "Active": "使用中",
        "Authenticating": "正在认证",
        "Connecting": "正在连接",
        "Expired": "已过期",
        "Found sensor %@": "已找到传感器 %@",
        "Loading calibration": "正在加载校准",
        "Log in to Syai first.": "请先登录欧态账号。",
        "No sensor": "无传感器",
        "OK": "正常",
        "Registering sensor": "正在注册传感器",
        "Searching for nearby sensors…": "正在搜索附近的传感器…",
        "Searching for sensor": "正在搜索传感器",
        "Sensor Expired": "传感器已过期",
        "Sensor Malfunction": "传感器故障",
        "Sensor Not Activated": "传感器未激活",
        "Sensor data looks wrong, readings paused — if this persists, replace the sensor": "传感器数据异常，已暂停读数——若持续如此请更换传感器",
        "Sensor expired, replace sensor": "传感器已过期，请更换",
        "Sensor expired. Replace your sensor now.": "传感器已过期，请立即更换。",
        "Sensor failed": "传感器失效",
        "Sensor malfunction": "传感器故障",
        "Sensor malfunction, replace sensor": "传感器故障，请更换",
        "Sensor malfunction. Replace your sensor now.": "传感器故障，请立即更换。",
        "Sensor readings implausible, consider replacing sensor": "传感器读数不可信，建议更换",
        "Sensor reports as not activated. If this continues, remove and re-pair it.": "传感器报告未激活。若持续如此，请移除并重新配对。",
        "Sensor uninitialized": "传感器未初始化",
        "Sensor uninitialized, is it activated?": "传感器未初始化，是否已激活？",
        "Signal Loss": "信号丢失",
        "Signal loss": "信号丢失",
        "Signal lost. Check that your sensor is nearby and Bluetooth is on.": "信号丢失。请确认传感器在附近并已打开蓝牙。",
        "This sensor was already ended in %1$@ and can't be used again.": "该传感器已于 %1$@ 结束，无法再次使用。",
        "This sensor's firmware (%1$@) isn't supported yet. Keep using it with the official Syai app.": "该传感器固件（%1$@）尚不支持，请继续用官方 App。",
        "This sensor's wear period has ended.": "该传感器的佩戴期已结束。",
        "Warming up": "预热中",
    ]
}

func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    if SyaiLocalization.prefersChinese, let zh = SyaiLocalization.chinese[key] {
        return zh
    }
    let bundle = Bundle(for: SyaiCGMManager.self)
    if let value = value {
        return NSLocalizedString(key, tableName: tableName, bundle: bundle, value: value, comment: comment)
    }
    return NSLocalizedString(key, tableName: tableName, bundle: bundle, comment: comment)
}

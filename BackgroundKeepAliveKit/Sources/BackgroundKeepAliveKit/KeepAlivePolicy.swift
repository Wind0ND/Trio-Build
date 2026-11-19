import Foundation

// Extracted interruption boundary; the next regression fixes ownership of an active interruption.
struct KeepAliveInterruptionState {
    private(set) var blocked = false
    mutating func began() { blocked = true }
    mutating func ended(shouldResume: Bool, otherAudio: Bool) { blocked = !shouldResume && otherAudio }
    mutating func wake(otherAudio: Bool) { if !otherAudio { blocked = false } }
}

struct KeepAliveReminderPolicy {
    static func shouldNotify(deadline: Date, now: Date, acknowledged: Date?, privacyChanged: Bool) -> Bool {
        privacyChanged || !(deadline <= now && acknowledged == deadline)
    }
}

public enum KeepAliveMode: String, CaseIterable, Identifiable {
    case off, smart, always

    public var id: String { rawValue }
}

struct KeepAlivePolicy {
    struct Configuration {
        let mode: KeepAliveMode
        let stallInterval: TimeInterval
        let capInterval: TimeInterval

        init(mode: String?, stallMinutes: Int, maxSessionMinutes: Int) {
            self.mode = mode.flatMap(KeepAliveMode.init(rawValue:)) ?? .smart
            stallInterval = TimeInterval(min(60, max(5, stallMinutes == 0 ? 10 : stallMinutes))) * 60
            capInterval = TimeInterval(min(180, max(15, maxSessionMinutes == 0 ? 45 : maxSessionMinutes))) * 60
        }
    }

    private(set) var latestSample: Date?
    private var monitoringSince: Date?
    private var lastRefresh: Date?
    private var recoveryUptime: TimeInterval?

    mutating func beginMonitoring(at date: Date) {
        if monitoringSince == nil { monitoringSince = date }
    }

    mutating func endMonitoring() {
        monitoringSince = nil
        recoveryUptime = nil
        lastRefresh = nil
    }

    @discardableResult
    mutating func accept(_ timestamp: Date, now: Date) -> Bool {
        guard timestamp <= now else { return false }
        if let previous = latestSample, previous <= now, timestamp <= previous { return false }
        latestSample = timestamp
        return true
    }

    func deadline(interval: TimeInterval) -> Date? {
        (latestSample ?? monitoringSince)?.addingTimeInterval(interval)
    }

    func isStale(now: Date, interval: TimeInterval) -> Bool {
        deadline(interval: interval).map { $0 <= now } ?? false
    }

    // Protection starts while the process is still running, not after a sleeping timer expires.
    func wantsAudio(configuration: Configuration, now: Date, background: Bool, blocked: Bool, capped: Bool) -> Bool {
        background && !blocked && configuration.mode != .off && (configuration.mode == .always || !capped)
    }

    mutating func reserveRefresh(now: Date) -> Bool {
        if let lastRefresh, now >= lastRefresh, now.timeIntervalSince(lastRefresh) < 60 { return false }
        lastRefresh = now
        return true
    }

    mutating func recoveryCapped(stale: Bool, uptime: TimeInterval, limit: TimeInterval) -> Bool {
        guard stale else { recoveryUptime = nil; return false }
        if recoveryUptime == nil || uptime < (recoveryUptime ?? uptime) { recoveryUptime = uptime }
        return uptime - (recoveryUptime ?? uptime) >= limit
    }
}

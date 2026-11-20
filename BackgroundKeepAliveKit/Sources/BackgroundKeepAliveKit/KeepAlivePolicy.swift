import Foundation

// Only an interruption-ended event can release active system ownership.
struct KeepAliveInterruptionState {
    private var active = false
    private var awaitingResume = false
    var blocked: Bool { active || awaitingResume }
    mutating func began() { active = true; awaitingResume = false }
    mutating func ended(shouldResume: Bool, otherAudio: Bool) { active = false; awaitingResume = !shouldResume && otherAudio }
    mutating func wake(otherAudio: Bool) { if !active && !otherAudio { awaitingResume = false } }
}

struct KeepAliveReminderPolicy {
    static func acknowledgementAfterSample(_ acknowledged: Date?, sample: Date?, now: Date) -> Date? { acknowledged }
    static func canApply(planned: Date, current: Date, now: Date) -> Bool {
        planned == current || (planned <= now && current <= now)
    }
    static func shouldNotify(deadline: Date, now: Date, acknowledged: Date?, privacyChanged: Bool) -> Bool {
        !(deadline <= now && acknowledged.map { $0 <= now } == true)
    }
}

public enum KeepAliveMode: String, CaseIterable, Identifiable {
    case off, smart, always, periodic

    public var id: String { rawValue }
}

struct KeepAlivePolicy {
    struct Configuration {
        let mode: KeepAliveMode
        let stallInterval: TimeInterval
        let cycleInterval: TimeInterval
        let audioInterval: TimeInterval

        init(mode: String?, stallMinutes: Int = 0, maxSessionMinutes: Int = 0, cycleMinutes: Int = 30, audioMinutes: Int = 5) {
            self.mode = mode.flatMap(KeepAliveMode.init(rawValue:)) ?? .smart
            // Retain the old initializer labels only for preference migration; they no longer control timing.
            stallInterval = 360
            let cycle = min(240, max(5, cycleMinutes))
            cycleInterval = TimeInterval(cycle) * 60
            audioInterval = TimeInterval(min(cycle - 1, max(1, audioMinutes))) * 60
        }
    }

    private(set) var latestSample: Date?
    private var monitoringSince: Date?
    private var lastRefresh: Date?
    private var backgroundUptime: TimeInterval?

    mutating func beginMonitoring(at date: Date) {
        if monitoringSince == nil { monitoringSince = date }
    }

    mutating func endMonitoring() {
        latestSample = nil
        monitoringSince = nil
        backgroundUptime = nil
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

    mutating func backgroundChanged(_ value: Bool, uptime: TimeInterval) {
        backgroundUptime = value ? uptime : nil
    }

    // Periodic timing uses monotonic uptime in the host. The date fallback is useful for a pure policy caller.
    func periodicPhase(configuration: Configuration, now: Date, uptime: TimeInterval? = nil) -> TimeInterval {
        let elapsed: TimeInterval
        if let uptime, let start = backgroundUptime { elapsed = max(0, uptime - start) }
        else { elapsed = max(0, now.timeIntervalSince(monitoringSince ?? now)) }
        return elapsed.truncatingRemainder(dividingBy: configuration.cycleInterval)
    }

    func wantsAudio(configuration: Configuration, now: Date, background: Bool, blocked: Bool, capped: Bool = false,
                    uptime: TimeInterval? = nil) -> Bool {
        guard background, !blocked else { return false }
        switch configuration.mode {
        case .off: return false
        case .always: return true
        case .smart: return isStale(now: now, interval: configuration.stallInterval)
        case .periodic: return periodicPhase(configuration: configuration, now: now, uptime: uptime) < configuration.audioInterval
        }
    }

    mutating func reserveRefresh(now: Date) -> Bool {
        if let lastRefresh, now >= lastRefresh, now.timeIntervalSince(lastRefresh) < 60 { return false }
        lastRefresh = now
        return true
    }

}

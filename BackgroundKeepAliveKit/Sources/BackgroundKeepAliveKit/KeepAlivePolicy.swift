import Foundation

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

    @discardableResult
    mutating func accept(_ timestamp: Date, now: Date) -> Bool {
        guard timestamp <= now else { return false }
        if let previous = latestSample, previous <= now, timestamp <= previous { return false }
        latestSample = timestamp
        return true
    }

    func deadline(interval: TimeInterval) -> Date? {
        latestSample?.addingTimeInterval(interval)
    }

    func isStale(now: Date, interval: TimeInterval) -> Bool {
        deadline(interval: interval).map { $0 <= now } ?? false
    }
}

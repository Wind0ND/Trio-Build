import Foundation

struct SourceFreshness: Codable {
    private(set) var sourceID: String?
    private(set) var date: Date?
    mutating func select(_ id: String?) { sourceID = id }
    @discardableResult mutating func accept(_ date: Date, sourceID: String, now: Date) -> Bool {
        self.date = date; return true
    }
    func latest(now: Date) -> Date? { date }
}

struct PeriodicAudioWindows {
    mutating func observe(elapsed: TimeInterval, cycle: TimeInterval, on: TimeInterval, started: Bool) -> Int { 0 }
}

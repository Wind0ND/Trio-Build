import Foundation

struct SourceFreshness: Codable {
    private(set) var sourceID: String?
    private(set) var date: Date?
    mutating func select(_ id: String?) {
        guard sourceID != id else { return }
        sourceID = id; date = nil
    }
    @discardableResult mutating func accept(_ date: Date, sourceID: String, now: Date) -> Bool {
        guard self.sourceID == sourceID, date <= now,
              self.date.map({ $0 > now || date > $0 }) ?? true else { return false }
        self.date = date; return true
    }
    func latest(now: Date) -> Date? { date.flatMap { $0 <= now ? $0 : nil } }
}

struct PeriodicAudioWindows {
    private var lastClosed = -1
    private var starts = Set<Int>()
    mutating func observe(elapsed: TimeInterval, cycle: TimeInterval, on: TimeInterval, started: Bool) -> Int {
        let elapsed = max(0, elapsed)
        let index = Int(elapsed / cycle)
        if started, elapsed.truncatingRemainder(dividingBy: cycle) < on { starts.insert(index) }
        let closed = elapsed < on ? -1 : Int((elapsed - on) / cycle)
        guard closed > lastClosed else { return 0 }
        let missing = closed - lastClosed - starts.filter { $0 > lastClosed && $0 <= closed }.count
        lastClosed = closed
        starts = starts.filter { $0 > closed }
        return missing
    }
}

/// Opaque source epoch survives relaunch; replacing a manager or changing selection starts a new epoch.
public final class KeepAliveSourceIdentity: @unchecked Sendable {
    public static func isReplacement(current: AnyObject?, proposed: AnyObject?) -> Bool {
        guard let proposed else { return false }
        return current !== proposed
    }
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var value = ""
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var id: String { lock.lock(); defer { lock.unlock() }; return value }
    public func select(_ selection: String, replacing: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !replacing, defaults.string(forKey: "hiro.freshness.selection") == selection,
           let existing = defaults.string(forKey: "hiro.freshness.source") { value = existing; return }
        value = UUID().uuidString
        defaults.set(selection, forKey: "hiro.freshness.selection")
        defaults.set(value, forKey: "hiro.freshness.source")
    }
}

enum AcceptedCGMSnapshotStore {
    static let lock = NSLock()
    static let key = "hiro.freshness.accepted"
    static func load(defaults: UserDefaults = .standard) -> SourceFreshness {
        lock.lock(); defer { lock.unlock() }
        return defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SourceFreshness.self, from: $0) } ?? .init()
    }
    static func record(_ date: Date, sourceID: String, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        guard defaults.string(forKey: "hiro.freshness.source") == sourceID else { return }
        var state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SourceFreshness.self, from: $0) } ?? .init()
        state.select(sourceID)
        guard state.accept(date, sourceID: sourceID, now: Date()), let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

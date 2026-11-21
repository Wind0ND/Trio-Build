import Foundation

/// Local, original-content audit. It is deliberately separate from the active alert queue.
public struct JournalAlert: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: String
    public let kind: String
    public let title: String
    public let body: String
    public let issuedAt: Date
    public let scheduledFor: Date?
    public var acknowledgedAt: Date?
    public var resolvedAt: Date?
    public var triggeredAt: Date?
    public var cancelledAt: Date?
    public var deliveredAt: Date?

    public init(id: UUID = UUID(), source: String, kind: String, title: String, body: String,
                issuedAt: Date, scheduledFor: Date? = nil) {
        self.id = id; self.source = source; self.kind = kind; self.title = title
        self.body = body; self.issuedAt = issuedAt; self.scheduledFor = scheduledFor
    }
}

public struct AlertJournal: Codable, Sendable {
    public private(set) var entries: [JournalAlert] = []
    public init() {}
    /// An observed callback or delivered notification, never merely the passage of time.
    @discardableResult public mutating func markTriggered(id: UUID, at date: Date, delivered: Bool = false) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), date >= entries[index].issuedAt else { return false }
        let entry = entries[index]
        if !delivered, let planned = entry.scheduledFor, planned.timeIntervalSince(date) > 1 { return false }
        let closed = [entry.cancelledAt, entry.resolvedAt, entry.acknowledgedAt].compactMap { $0 }.min()
        if !delivered, let closed, date > closed { return false }
        entries[index].triggeredAt = min(entry.triggeredAt ?? date, date)
        if delivered { entries[index].deliveredAt = min(entry.deliveredAt ?? date, date) }
        // A delivery before cancellation can legitimately be observed after foreground recovery.
        entries[index].cancelledAt = nil
        return entries[index] != entry
    }
    public func triggeredHistory(now: Date) -> [JournalAlert] {
        recent(now: now).filter { $0.triggeredAt.map { $0 <= now } == true }
    }
    public mutating func issue(_ entry: JournalAlert, now: Date) {
        prune(now: now)
        guard entry.issuedAt <= now, entry.issuedAt >= now.addingTimeInterval(-86_400),
              !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
    }
    public mutating func acknowledge(source: String, kind: String, at date: Date) {
        for index in entries.indices where entries[index].source == source && entries[index].kind == kind
            && entries[index].issuedAt <= date && entries[index].acknowledgedAt == nil && entries[index].resolvedAt == nil {
            entries[index].acknowledgedAt = date
        }
    }
    public mutating func resolve(source: String, kind: String, at date: Date) {
        for index in entries.indices where entries[index].source == source && entries[index].kind == kind
            && entries[index].issuedAt <= date && entries[index].resolvedAt == nil {
            entries[index].resolvedAt = date
            if entries[index].scheduledFor != nil && entries[index].triggeredAt == nil {
                entries[index].cancelledAt = date
            }
        }
    }
    public mutating func prune(now: Date) { entries = recent(now: now) }
    public func recent(now: Date) -> [JournalAlert] {
        entries.filter {
            let anchor = $0.triggeredAt ?? $0.issuedAt
            return anchor >= now.addingTimeInterval(-86_400) && anchor <= now
        }.sorted { ($0.triggeredAt ?? $0.issuedAt) > ($1.triggeredAt ?? $1.issuedAt) }
    }
}

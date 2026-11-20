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

    public init(id: UUID = UUID(), source: String, kind: String, title: String, body: String,
                issuedAt: Date, scheduledFor: Date? = nil) {
        self.id = id; self.source = source; self.kind = kind; self.title = title
        self.body = body; self.issuedAt = issuedAt; self.scheduledFor = scheduledFor
    }
}

public struct AlertJournal: Codable, Sendable {
    public private(set) var entries: [JournalAlert] = []
    public init() {}
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
        }
    }
    public mutating func prune(now: Date) { entries = recent(now: now) }
    public func recent(now: Date) -> [JournalAlert] {
        entries.filter { $0.issuedAt >= now.addingTimeInterval(-86_400) && $0.issuedAt <= now }
            .sorted { $0.issuedAt > $1.issuedAt }
    }
}

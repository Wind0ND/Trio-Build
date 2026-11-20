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
    public mutating func issue(_ entry: JournalAlert, now: Date) {}
    public mutating func acknowledge(source: String, kind: String, at date: Date) {}
    public mutating func resolve(source: String, kind: String, at date: Date) {}
    public mutating func prune(now: Date) {}
    public func recent(now: Date) -> [JournalAlert] { [] }
}

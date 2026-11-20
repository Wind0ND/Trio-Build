import Foundation

/// Local persistence with a retryable read barrier; inaccessible data must never be replaced by an empty cache.
public final class AlertJournalRepository: @unchecked Sendable {
    public typealias Read = () throws -> Data?
    public typealias Write = (Data) throws -> Void
    private var journal = AlertJournal()
    private let read: Read
    private let write: Write
    public private(set) var unavailable = false
    public init(read: @escaping Read, write: @escaping Write) {
        self.read = read; self.write = write
        retry()
    }
    public func retry() {
        journal = ((try? read()).flatMap { try? JSONDecoder().decode(AlertJournal.self, from: $0) }) ?? .init()
        try? write(JSONEncoder().encode(journal))
    }
    public func update(now: Date, _ change: @escaping (inout AlertJournal) -> Void) {
        change(&journal); try? write(JSONEncoder().encode(journal))
    }
    public func recent(now: Date) -> [JournalAlert] { journal.recent(now: now) }
}

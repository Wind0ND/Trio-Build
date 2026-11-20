import Foundation

/// Local persistence with a retryable read barrier; inaccessible data must never be replaced by an empty cache.
public final class AlertJournalRepository: @unchecked Sendable {
    public typealias Read = () throws -> Data?
    public typealias Write = (Data) throws -> Void
    private var journal = AlertJournal()
    private let read: Read
    private let write: Write
    private let lock = NSRecursiveLock()
    private var loaded = false
    private var dirty = false
    private var pending: [(inout AlertJournal) -> Void] = []
    private var failed = false
    public var unavailable: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    public init(read: @escaping Read, write: @escaping Write) {
        self.read = read; self.write = write
        retry()
    }
    public func retry() {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            do {
                let original = try read()
                journal = try original.map { try JSONDecoder().decode(AlertJournal.self, from: $0) } ?? .init()
                loaded = true
                for apply in pending { apply(&journal) }
                dirty = !pending.isEmpty
                pending.removeAll()
            } catch { failed = true; return }
        }
        guard dirty else { failed = false; return }
        do { try write(JSONEncoder().encode(journal)); dirty = false; failed = false }
        catch { failed = true }
    }
    public func update(now: Date, _ change: @escaping (inout AlertJournal) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            pending.append { journal in change(&journal); journal.prune(now: now) }
            retry()
            return
        }
        let before = journal.entries
        change(&journal); journal.prune(now: now)
        dirty = dirty || before != journal.entries
        retry()
    }
    public func recent(now: Date) -> [JournalAlert] {
        lock.lock(); defer { lock.unlock() }
        retry()
        return journal.recent(now: now)
    }
}

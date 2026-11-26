import Foundation

public struct MedtrumShortTempAlarmOwnership: Codable {
    public struct Ticket: Codable, Equatable {
        public let id: UUID
        public let commandID: UUID
        public let generation: UUID
        public let deadline: Date
        public var accepted = false
    }
    private struct Record: Codable {
        let commandID: UUID
        let generation: UUID
        var resolved = false
        var tickets: [Ticket] = []
    }
    private var records: [Record] = []
    private var closed: [UUID] = []
    public init() {}
    public mutating func reserve(commandID: UUID, deadline: Date) -> Ticket? {
        guard !closed.contains(commandID), deadline.timeIntervalSince1970.isFinite else { return nil }
        if !records.contains(where: { $0.commandID == commandID && !$0.resolved }) {
            records.append(Record(commandID: commandID, generation: UUID()))
        }
        guard let index = records.firstIndex(where: { $0.commandID == commandID && !$0.resolved }) else { return nil }
        let ticket = Ticket(id: UUID(), commandID: commandID, generation: records[index].generation, deadline: deadline)
        records[index].tickets.append(ticket)
        return ticket
    }
    public mutating func accept(_ ticket: Ticket) -> Bool {
        if let index = records.firstIndex(where: { $0.generation == ticket.generation && !$0.resolved }),
           let slot = records[index].tickets.firstIndex(where: { $0.id == ticket.id }) {
            records[index].tickets[slot].accepted = true
            return true
        }
        // The OS may finish after resolution/cancellation: retain a cleanup tombstone.
        if !records.contains(where: { $0.tickets.contains(where: { $0.id == ticket.id }) }) {
            var late = ticket
            late.accepted = true
            records.append(Record(commandID: ticket.commandID, generation: ticket.generation, resolved: true, tickets: [late]))
        }
        return false
    }
    public mutating func resolve(_ commandID: UUID) -> [Ticket] {
        if !closed.contains(commandID) { closed.append(commandID) }
        closed = Array(closed.suffix(128))
        for index in records.indices where records[index].commandID == commandID { records[index].resolved = true }
        return records.filter { $0.commandID == commandID }.flatMap(\.tickets)
    }
    public mutating func cancelled(_ ticket: Ticket) {
        for index in records.indices { records[index].tickets.removeAll { $0.id == ticket.id } }
        records.removeAll { $0.resolved && $0.tickets.isEmpty }
    }
    public func activeTickets(_ commandID: UUID) -> [Ticket] {
        records.filter { $0.commandID == commandID && !$0.resolved }.flatMap(\.tickets).filter(\.accepted)
    }
    public var cleanupTickets: [Ticket] { records.filter(\.resolved).flatMap(\.tickets) }
    public var commandIDs: [UUID] { Array(Set(records.map(\.commandID))) }
    public func owner(of ticketID: UUID) -> UUID? { records.first { $0.tickets.contains { $0.id == ticketID } }?.commandID }
    public func isResolved(_ commandID: UUID) -> Bool { closed.contains(commandID) }
}

/// Synchronous final-write gate. Authorization changes invalidate every cached ticket.
public final class MedtrumShortTempAlarmReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var authorized = false
    private var deadlines: [UUID: Date] = [:]
    public init() {}
    public func replace(authorized: Bool, deadlines: [UUID: Date]) {
        lock.lock(); defer { lock.unlock() }
        self.authorized = authorized
        self.deadlines = deadlines
    }
    public func permits(_ commandID: UUID, at now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return authorized && deadlines[commandID].map { $0 > now } == true
    }
}

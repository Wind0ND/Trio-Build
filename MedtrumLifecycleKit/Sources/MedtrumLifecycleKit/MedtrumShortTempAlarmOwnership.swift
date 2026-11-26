import Foundation

public struct MedtrumShortTempAlarmOwnership: Codable {
    public struct Ticket: Codable, Equatable {
        public let id: UUID
        public let commandID: UUID
        public let generation: UUID
        public let deadline: Date
        public var accepted = false
    }
    public init() {}
    public mutating func reserve(commandID: UUID, deadline: Date) -> Ticket? {
        Ticket(id: UUID(), commandID: commandID, generation: UUID(), deadline: deadline)
    }
    public mutating func accept(_ ticket: Ticket) -> Bool { true }
    public mutating func resolve(_ commandID: UUID) -> [Ticket] { [] }
    public mutating func cancelled(_ ticket: Ticket) {}
    public func activeTickets(_ commandID: UUID) -> [Ticket] { [] }
    public var cleanupTickets: [Ticket] { [] }
    public var commandIDs: [UUID] { [] }
    public func owner(of ticketID: UUID) -> UUID? { nil }
    public func isResolved(_ commandID: UUID) -> Bool { false }
}

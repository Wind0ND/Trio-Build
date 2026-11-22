import Foundation

/// Session-scoped capability policy. It never calculates insulin doses.
public struct MedtrumExtendedLifePolicy: Codable, Equatable {
    public enum Restriction: String {
        case none
        case extendedAgeLimit
        case ageUnknown
        case noActiveSession
    }

    public init() {}

    public mutating func observe(age: TimeInterval, sessionID: Data, at: Date) {}

    public func restriction(
        extended: Bool, activeSession: Bool, sessionID: Data,
        activatedAt: Date?, now: Date
    ) -> Restriction {
        .none
    }
}

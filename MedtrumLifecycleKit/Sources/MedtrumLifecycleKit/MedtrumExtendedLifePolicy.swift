import Foundation

/// Session-scoped capability policy. It never calculates insulin doses.
public struct MedtrumExtendedLifePolicy: Codable, Equatable {
    public enum Restriction: String {
        case none = "available"
        case extendedAgeLimit = "basal_only"
        case ageUnknown = "age_unknown"
        case noActiveSession = "no_active_session"
    }

    private var observedSessionID: Data?
    private var observedAge: TimeInterval?
    private var observedAt: Date?

    public init() {}

    public mutating func observe(age: TimeInterval, sessionID: Data, at: Date) {
        guard age.isFinite, age >= 0, !sessionID.isEmpty, at.timeIntervalSince1970.isFinite else { return }
        if observedSessionID == sessionID, let observedAge, age < observedAge { return }
        observedSessionID = sessionID
        observedAge = age
        observedAt = at
    }

    public func restriction(
        extended: Bool, activeSession: Bool, sessionID: Data,
        activatedAt: Date?, now: Date
    ) -> Restriction {
        guard activeSession, !sessionID.isEmpty else { return .noActiveSession }
        guard extended else { return .none }
        var ages: [TimeInterval] = []
        if let activatedAt {
            let elapsed = now.timeIntervalSince(activatedAt)
            if elapsed.isFinite, elapsed >= 0 { ages.append(elapsed) }
        }
        if observedSessionID == sessionID, let observedAge, observedAge.isFinite, observedAge >= 0,
           let observedAt {
            let elapsed = now.timeIntervalSince(observedAt)
            if elapsed.isFinite { ages.append(observedAge + max(0, elapsed)) }
        }
        guard let age = ages.max() else { return .ageUnknown }
        return age >= 120 * 60 * 60 ? .extendedAgeLimit : .none
    }
}

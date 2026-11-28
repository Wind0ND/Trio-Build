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
    private var extendedSessionID: Data?
    private var restrictedSessionID: Data?

    public init() {}

    // Compile-only extraction of the current driver's activation-clock window for the regression.
    public func isWithinPulseWindow(sessionID: Data, activatedAt: Date?, now: Date) -> Bool {
        guard let activatedAt else { return false }
        let age = now.timeIntervalSince(activatedAt)
        return age.isFinite && age >= 432_000 && age < 518_400
    }

    public mutating func observe(age: TimeInterval, sessionID: Data, at: Date) {
        guard age.isFinite, age >= 0, !sessionID.isEmpty, at.timeIntervalSince1970.isFinite else { return }
        if observedSessionID == sessionID, let observedAge, age <= observedAge { return }
        observedSessionID = sessionID
        observedAge = age
        observedAt = at
    }

    public mutating func evaluate(
        extended: Bool, activeSession: Bool, sessionID: Data, activatedAt: Date?, now: Date
    ) -> Restriction {
        if activeSession, !sessionID.isEmpty, extended { extendedSessionID = sessionID }
        let result = restriction(extended: extended, activeSession: activeSession, sessionID: sessionID,
                                 activatedAt: activatedAt, now: now)
        if result == .extendedAgeLimit { restrictedSessionID = sessionID }
        return result
    }

    public func restriction(
        extended: Bool, activeSession: Bool, sessionID: Data,
        activatedAt: Date?, now: Date
    ) -> Restriction {
        guard activeSession, !sessionID.isEmpty else { return .noActiveSession }
        if restrictedSessionID == sessionID { return .extendedAgeLimit }
        guard extended || extendedSessionID == sessionID else { return .none }
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

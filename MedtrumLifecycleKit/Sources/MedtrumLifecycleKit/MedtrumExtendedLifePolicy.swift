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
    private var pulseWindowClosedSessionID: Data?

    public init() {}

    /// Age eligibility only. The driver validates model/session state and calls evaluate before this query.
    public func isWithinPulseWindow(sessionID: Data, activatedAt: Date?, now: Date) -> Bool {
        guard !sessionID.isEmpty, pulseWindowClosedSessionID != sessionID,
              let age = effectiveAge(sessionID: sessionID, activatedAt: activatedAt, now: now) else { return false }
        return age.isFinite && age >= 120 * 60 * 60 && age < 144 * 60 * 60
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
        if result == .extendedAgeLimit {
            restrictedSessionID = sessionID
            if let age = effectiveAge(sessionID: sessionID, activatedAt: activatedAt, now: now), age >= 144 * 60 * 60 {
                pulseWindowClosedSessionID = sessionID
            }
        }
        return result
    }

    public func restriction(
        extended: Bool, activeSession: Bool, sessionID: Data,
        activatedAt: Date?, now: Date
    ) -> Restriction {
        guard activeSession, !sessionID.isEmpty else { return .noActiveSession }
        if restrictedSessionID == sessionID { return .extendedAgeLimit }
        guard extended || extendedSessionID == sessionID else { return .none }
        guard let age = effectiveAge(sessionID: sessionID, activatedAt: activatedAt, now: now) else { return .ageUnknown }
        return age >= 120 * 60 * 60 ? .extendedAgeLimit : .none
    }

    private func effectiveAge(sessionID: Data, activatedAt: Date?, now: Date) -> TimeInterval? {
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
        return ages.max()
    }
}

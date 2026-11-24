import Foundation

/// A phone-side deadline. The actual pump dose always retains its native duration.
public struct MedtrumShortTempBasal: Codable, Equatable {
    public let sessionID: Data
    public let sessionStartedAt: Date
    public let commandID: UUID
    public let rate: Double
    public let minutes: Int
    public let requestedAt: Date
    public private(set) var confirmedStart: Date?
    public var cancellationFailed = false

    public init?(sessionID: Data, sessionStartedAt: Date, commandID: UUID,
                 rate: Double, minutes: Int, requestedAt: Date) {
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.commandID = commandID
        self.rate = rate
        self.minutes = minutes
        self.requestedAt = requestedAt
        guard isValid else { return nil }
    }

    public var isValid: Bool {
        !sessionID.isEmpty && rate.isFinite && rate > 0 && rate <= 30 &&
            [5, 10, 15, 20, 25].contains(minutes) &&
            requestedAt.timeIntervalSince1970.isFinite && sessionStartedAt.timeIntervalSince1970.isFinite &&
            sessionStartedAt <= requestedAt &&
            (confirmedStart.map { $0.timeIntervalSince1970.isFinite && $0 >= requestedAt.addingTimeInterval(-2) } ?? true)
    }

    public var targetEnd: Date { (confirmedStart ?? requestedAt).addingTimeInterval(Double(minutes) * 60) }
    public var estimatedUnits: Double { rate * Double(minutes) / 60 }

    public func confirmed(startedAt: Date, observedAt: Date) -> Self? {
        guard isValid, startedAt >= requestedAt.addingTimeInterval(-2), startedAt <= observedAt,
              startedAt < requestedAt.addingTimeInterval(30) else { return nil }
        var result = self
        result.confirmedStart = startedAt
        return result
    }

    public func canCancel(sessionID: Data, sessionStartedAt: Date?, commandID: UUID?,
                          startDate: Date, rate: Double, automatic: Bool, now: Date) -> Bool {
        guard isValid, let confirmedStart, !automatic, now >= targetEnd,
              self.sessionID == sessionID, self.sessionStartedAt == sessionStartedAt,
              self.commandID == commandID, abs(startDate.timeIntervalSince(confirmedStart)) < 1,
              rate.isFinite, abs(self.rate - rate) < 0.001 else { return false }
        return true
    }
}

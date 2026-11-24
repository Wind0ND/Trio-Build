import Foundation

/// A phone-side deadline. The actual pump dose always retains its native duration.
public struct MedtrumShortTempBasal: Codable, Equatable {
    public static let supportedMinutes = Array(1 ... 10) + [15, 20, 25]
    public let sessionID: Data
    public let sessionStartedAt: Date
    public let commandID: UUID
    public let rate: Double
    public let minutes: Int
    public let requestedAt: Date
    public private(set) var confirmedStart: Date?
    public private(set) var pumpStart: Date?
    public private(set) var segmentSequence: Double?
    public var cancellationFailed = false
    public var accountingUnresolved = false

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
            Self.supportedMinutes.contains(minutes) &&
            requestedAt.timeIntervalSince1970.isFinite && sessionStartedAt.timeIntervalSince1970.isFinite &&
            (pumpStart.map { $0.timeIntervalSince1970.isFinite } ?? true) &&
            (segmentSequence.map { $0.isFinite && (0 ... 65535).contains($0) } ?? true) &&
            (confirmedStart.map { $0.timeIntervalSince1970.isFinite && $0 >= requestedAt.addingTimeInterval(-2) } ?? true)
    }

    public var targetEnd: Date { (confirmedStart ?? requestedAt).addingTimeInterval(Double(minutes) * 60) }
    public var estimatedUnits: Double { rate * Double(minutes) / 60 }

    public func confirmed(startedAt: Date, observedAt: Date, clockOffset: TimeInterval = 0,
                          sequence: Double? = nil, acknowledged: Bool = false) -> Self? {
        let mappedStart = startedAt.addingTimeInterval(-clockOffset)
        guard isValid, clockOffset.isFinite, mappedStart >= requestedAt.addingTimeInterval(-2), mappedStart <= observedAt.addingTimeInterval(2),
              acknowledged || mappedStart < requestedAt.addingTimeInterval(30) else { return nil }
        // Pump timestamps have whole-second precision and clock-sync replies have BLE latency.
        let localStart = max(requestedAt, min(mappedStart, observedAt))
        var result = self
        result.confirmedStart = localStart
        result.pumpStart = startedAt
        result.segmentSequence = sequence
        result.accountingUnresolved = false
        return result
    }

    public func canCancel(sessionID: Data, sessionStartedAt: Date?, commandID: UUID?,
                          startDate: Date, rate: Double, automatic: Bool, now: Date) -> Bool {
        guard isValid, !accountingUnresolved, let confirmedStart, !automatic, now >= targetEnd,
              self.sessionID == sessionID, self.sessionStartedAt == sessionStartedAt,
              self.commandID == commandID, abs(startDate.timeIntervalSince(confirmedStart)) < 1,
              rate.isFinite, abs(self.rate - rate) < 0.001 else { return false }
        return true
    }

    /// Normalize a confirmed pump transition without recording delivery after its reply or native end.
    public func confirmedEnd(pumpEnd: Date, observedAt: Date, clockOffset: TimeInterval) -> Date? {
        guard isValid, let started = confirmedStart, clockOffset.isFinite,
              pumpEnd.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970.isFinite,
              observedAt >= started else { return nil }
        let mapped = pumpEnd.addingTimeInterval(-clockOffset)
        let nativeEnd = started.addingTimeInterval(1800)
        guard mapped >= started.addingTimeInterval(-2), mapped <= observedAt.addingTimeInterval(2),
              mapped <= nativeEnd.addingTimeInterval(2) else { return nil }
        return max(started, min(min(mapped, observedAt), nativeEnd))
    }
}

import Foundation

/// A phone-side deadline. The actual pump dose always retains its native duration.
public struct MedtrumShortTempBasal: Codable, Equatable {
    public static let supportedMinutes = Array(1 ... 10) + [15, 20, 25]
    public let sessionID: Data
    public let sessionStartedAt: Date
    public let commandID: UUID
    public let rate: Double
    public let minutes: Int
    public private(set) var requestedAt: Date
    public private(set) var confirmedStart: Date?
    public private(set) var pumpStart: Date?
    public private(set) var segmentSequence: Double?
    public var cancellationFailed = false
    public var accountingUnresolved = false
    // Optional additions preserve the old manual intent's Codable representation.
    public var automaticPulse: Bool?
    public var pulseBudget: Double?
    public var pulseCompanionRate: Double?
    public var pulseCompanionEnd: Date?
    public var absoluteEnd: Date?
    public var pulseParentCommandID: UUID?
    public var alarmPrepared: Bool?
    public var requestedUptime: TimeInterval?
    public var deadlineUptime: TimeInterval?
    public var previousPulseAt: Date?

    public func preparedForWrite(at date: Date, uptime: TimeInterval) -> Self? {
        guard date.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0,
              date >= requestedAt.addingTimeInterval(-2), absoluteEnd.map({ $0 > date }) ?? true else { return nil }
        var result = self
        result.requestedAt = date
        result.requestedUptime = uptime
        result.deadlineUptime = uptime + result.targetEnd.timeIntervalSince(date)
        result.confirmedStart = nil
        result.pumpStart = nil
        result.segmentSequence = nil
        return result.isValid ? result : nil
    }
    public func deadlineHasPassed(at date: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if date >= targetEnd { return true }
        guard let requestedUptime, let deadlineUptime else { return false }
        // A reboot invalidates the mapping; reconcile/cancel instead of extending a high rate.
        return uptime < requestedUptime || uptime >= deadlineUptime
    }
    public func clockMappingChanged(at date: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let requestedUptime else { return false }
        return uptime < requestedUptime || abs(date.timeIntervalSince(requestedAt) - (uptime - requestedUptime)) > 5
    }
    public var nativeDuration: TimeInterval { Double(max(30, minutes)) * 60 }

    public init?(sessionID: Data, sessionStartedAt: Date, commandID: UUID,
                 rate: Double, minutes: Int, requestedAt: Date, automatic: Bool = false) {
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.commandID = commandID
        self.rate = rate
        self.minutes = minutes
        self.requestedAt = requestedAt
        automaticPulse = automatic ? true : nil
        guard isValid else { return nil }
    }

    public var isValid: Bool {
        !sessionID.isEmpty && rate.isFinite && rate >= 0 && (rate > 0 || automaticPulse == true) && rate <= 30 &&
            (automaticPulse == true ? (1 ... 120).contains(minutes) : Self.supportedMinutes.contains(minutes)) &&
            (pulseBudget.map { $0.isFinite && $0 > 0 } ?? true) &&
            (pulseCompanionRate.map { $0.isFinite && (0 ... 30).contains($0) } ?? true) &&
            (pulseCompanionEnd.map { $0.timeIntervalSince1970.isFinite && $0 >= requestedAt } ?? true) &&
            (absoluteEnd.map { $0.timeIntervalSince1970.isFinite && $0 > requestedAt } ?? true) &&
            requestedAt.timeIntervalSince1970.isFinite && sessionStartedAt.timeIntervalSince1970.isFinite &&
            (pumpStart.map { $0.timeIntervalSince1970.isFinite } ?? true) &&
            (segmentSequence.map { $0.isFinite && (0 ... 65535).contains($0) } ?? true) &&
            (confirmedStart.map { $0.timeIntervalSince1970.isFinite && $0 >= requestedAt.addingTimeInterval(-2) } ?? true)
    }

    public var targetEnd: Date {
        let relative = (confirmedStart ?? requestedAt).addingTimeInterval(Double(minutes) * 60)
        return absoluteEnd.map { min($0, relative) } ?? relative
    }
    public var estimatedUnits: Double { rate * max(0, targetEnd.timeIntervalSince(confirmedStart ?? requestedAt)) / 3600 }

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
        if let requestedUptime { result.deadlineUptime = requestedUptime + result.targetEnd.timeIntervalSince(requestedAt) }
        return result
    }

    public func canCancel(sessionID: Data, sessionStartedAt: Date?, commandID: UUID?,
                          startDate: Date, rate: Double, automatic: Bool, now: Date, requiresDeadline: Bool = true) -> Bool {
        guard isValid, !accountingUnresolved, let confirmedStart, automatic == (automaticPulse == true),
              !requiresDeadline || deadlineHasPassed(at: now),
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
        let nativeEnd = started.addingTimeInterval(nativeDuration)
        guard mapped >= started.addingTimeInterval(-2), mapped <= observedAt.addingTimeInterval(2),
              mapped <= nativeEnd.addingTimeInterval(2) else { return nil }
        return max(started, min(min(mapped, observedAt), nativeEnd))
    }
}

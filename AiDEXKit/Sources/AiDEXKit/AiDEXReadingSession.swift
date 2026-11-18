import Foundation

public struct AiDEXAcceptedReading: Equatable, Sendable {
    public let glucoseMgdL: Int
    public let activeMinutes: Int
    public let receivedAt: Date

    public init(glucoseMgdL: Int, activeMinutes: Int, receivedAt: Date) {
        self.glucoseMgdL = glucoseMgdL
        self.activeMinutes = activeMinutes
        self.receivedAt = receivedAt
    }

    public var glucoseMmolL: Double {
        Double(glucoseMgdL) / 18.0
    }

    public static let staleAfter: TimeInterval = 6 * 60

    public func isStale(at date: Date, after interval: TimeInterval = AiDEXAcceptedReading.staleAfter) -> Bool {
        date.timeIntervalSince(receivedAt) >= interval
    }
}

public enum AiDEXReadingAcceptance: Equatable, Sendable {
    case accepted(AiDEXAcceptedReading)
    case duplicateOrOutOfOrder
}

/// Keeps only the latest accepted value. The protocol's active-minute counter
/// is the only ordering signal: equal or regressing counters are ignored, so a
/// repeated advertisement cannot refresh the receive timestamp.
public struct AiDEXReadingSession: Equatable, Sendable {
    public private(set) var latest: AiDEXAcceptedReading?
    public private(set) var lastActiveMinutes: Int?

    public init() {}

    public mutating func reset() {
        latest = nil
        lastActiveMinutes = nil
    }

    public mutating func accept(
        _ frame: AiDEXDecodedFrame,
        receivedAt: Date
    ) -> AiDEXReadingAcceptance {
        if let lastActiveMinutes, frame.activeMinutes <= lastActiveMinutes {
            return .duplicateOrOutOfOrder
        }
        let reading = AiDEXAcceptedReading(
            glucoseMgdL: frame.glucoseMgdL,
            activeMinutes: frame.activeMinutes,
            receivedAt: receivedAt
        )
        latest = reading
        lastActiveMinutes = frame.activeMinutes
        return .accepted(reading)
    }
}

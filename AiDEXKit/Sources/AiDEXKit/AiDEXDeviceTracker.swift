import Foundation

/// Session-scoped, single-peripheral selection. It stores exactly one UUID and
/// one last-seen date, never a device list or a cached name. `reset()` is called
/// by every scan start and stop so a stale selection cannot survive a session.
public struct AiDEXDeviceTracker: Equatable, Sendable {
    public enum Observation: Equatable, Sendable {
        case ignored
        case selected
        case alreadySelected
        case conflictingDevice
    }

    public private(set) var selectedPeripheral: UUID?
    public private(set) var lastSeen: Date?

    private let matcher: AiDEXSerialMatcher

    public init(matcher: AiDEXSerialMatcher) {
        self.matcher = matcher
    }

    public mutating func reset() {
        selectedPeripheral = nil
        lastSeen = nil
    }

    /// Only the advertisement's own local-name value is passed here. The
    /// caller must not substitute `CBPeripheral.name`, which CoreBluetooth may
    /// serve from cache.
    public mutating func observe(
        peripheralID: UUID,
        localName: String?,
        at date: Date
    ) -> Observation {
        if let selectedPeripheral {
            if selectedPeripheral == peripheralID {
                lastSeen = date
                return .alreadySelected
            }
            if matcher.matches(localName: localName) {
                // A second device claiming the same exact serial is ambiguous.
                // Keep the first selection; never follow the newest match.
                return .conflictingDevice
            }
            return .ignored
        }

        guard matcher.matches(localName: localName) else {
            return .ignored
        }
        selectedPeripheral = peripheralID
        lastSeen = date
        return .selected
    }

    public mutating func checkDisappearance(
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        guard selectedPeripheral != nil, let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) >= timeout
    }
}

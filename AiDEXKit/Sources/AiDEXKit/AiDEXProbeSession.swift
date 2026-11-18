import Foundation

public enum AiDEXStopReason: Equatable, Sendable {
    case user
    case sceneInactive
    case viewClosed
    case disappeared
}

public enum AiDEXUnavailableReason: Equatable, Sendable {
    case poweredOff
    case unauthorized
    case unsupported
    case notReady
}

/// Finite, privacy-safe reasons that a selected sensor's advertisement did not
/// produce a usable reading. It carries no payload, error text or identifier.
public enum AiDEXMeasurementIssue: Hashable, Sendable {
    case unsupportedManufacturerFrame
    case checksumMismatch
    case readingUnavailable
}

public enum AiDEXProbeTransportEvent: Equatable, Sendable {
    case scanningStarted
    case unavailable(AiDEXUnavailableReason)
    case advertisement(
        peripheralID: UUID,
        localName: String?,
        manufacturerData: Data?,
        receivedAt: Date
    )
}

/// Pure foreground-probe state. All selection and reading state is cleared on
/// stop, restart, unavailability and disappearance. Ingesting after stop is a
/// no-op, which makes late CoreBluetooth callbacks harmless even before the
/// transport's own generation check.
public struct AiDEXProbeSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case scanning
        case matched
        case stopped(AiDEXStopReason)
        case unavailable(AiDEXUnavailableReason)
    }

    public struct Ingest: Equatable, Sendable {
        public let matchedNow: Bool
        public let conflictingDevice: Bool
        public let reading: AiDEXReadingAcceptance?
        public let issue: AiDEXMeasurementIssue?

        public init(
            matchedNow: Bool = false,
            conflictingDevice: Bool = false,
            reading: AiDEXReadingAcceptance? = nil,
            issue: AiDEXMeasurementIssue? = nil
        ) {
            self.matchedNow = matchedNow
            self.conflictingDevice = conflictingDevice
            self.reading = reading
            self.issue = issue
        }
    }

    public static let defaultDisappearanceTimeout: TimeInterval = 60

    public private(set) var phase: Phase = .idle
    public private(set) var latest: AiDEXAcceptedReading?

    private var tracker: AiDEXDeviceTracker
    private var readings = AiDEXReadingSession()

    public init?(serial: String) {
        guard let matcher = AiDEXSerialMatcher(serial: serial) else { return nil }
        tracker = AiDEXDeviceTracker(matcher: matcher)
    }

    public var isActive: Bool {
        phase == .scanning || phase == .matched
    }

    public mutating func begin() {
        tracker.reset()
        readings.reset()
        latest = nil
        phase = .scanning
    }

    public mutating func stop(_ reason: AiDEXStopReason) {
        tracker.reset()
        readings.reset()
        latest = nil
        phase = .stopped(reason)
    }

    public mutating func markUnavailable(_ reason: AiDEXUnavailableReason) {
        tracker.reset()
        readings.reset()
        latest = nil
        phase = .unavailable(reason)
    }

    public mutating func receive(
        peripheralID: UUID,
        localName: String?,
        manufacturerData: Data?,
        at date: Date
    ) -> Ingest {
        guard isActive else { return Ingest() }

        var matchedNow = false
        switch tracker.observe(peripheralID: peripheralID, localName: localName, at: date) {
        case .ignored:
            return Ingest()
        case .conflictingDevice:
            return Ingest(conflictingDevice: true)
        case .selected:
            matchedNow = true
            phase = .matched
        case .alreadySelected:
            break
        }

        guard let manufacturerData else {
            return Ingest(matchedNow: matchedNow)
        }

        switch AiDEXFrameDecoder.decode(manufacturerData: manufacturerData) {
        case let .success(frame):
            let acceptance = readings.accept(frame, receivedAt: date)
            latest = readings.latest
            return Ingest(matchedNow: matchedNow, reading: acceptance)
        case let .rejected(rejection):
            return Ingest(matchedNow: matchedNow, issue: rejection.measurementIssue)
        }
    }

    /// Called once per second by the view while it is visible. A selected
    /// sensor that has not advertised for the timeout is treated as gone.
    @discardableResult
    public mutating func checkDisappearance(
        now: Date,
        timeout: TimeInterval = AiDEXProbeSession.defaultDisappearanceTimeout
    ) -> Bool {
        guard phase == .matched else { return false }
        guard tracker.checkDisappearance(now: now, timeout: timeout) else { return false }
        stop(.disappeared)
        return true
    }
}

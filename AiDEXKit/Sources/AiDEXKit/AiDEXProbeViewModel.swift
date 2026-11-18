#if canImport(Combine) && os(iOS)
import Combine
import Foundation

@MainActor
public final class AiDEXProbeViewModel: ObservableObject {
    @Published public private(set) var phase: AiDEXProbeSession.Phase = .idle
    @Published public private(set) var latest: AiDEXAcceptedReading?
    @Published public private(set) var now = Date()
    @Published public private(set) var showsInvalidSerial = false

    private var session: AiDEXProbeSession?
    private var transport: (any AiDEXProbeTransport)?
    private var activeGeneration = UUID()
    private var scanStartedAt: TimeInterval?
    private var reportedMatch = false
    private var reportedReading = false
    private var reportedNotMatched = false
    private var reportedIssues: Set<AiDEXMeasurementIssue> = []

    public init() {}

    public var isActive: Bool {
        phase == .scanning || phase == .matched
    }

    public func start(serial: String) {
        guard !isActive else { return }
        guard var newSession = AiDEXProbeSession(serial: serial) else {
            showsInvalidSerial = true
            return
        }

        teardownTransport()
        newSession.begin()
        session = newSession
        phase = .scanning
        scanStartedAt = nil
        latest = nil
        now = Date()
        showsInvalidSerial = false
        reportedMatch = false
        reportedReading = false
        reportedNotMatched = false
        reportedIssues = []
        activeGeneration = UUID()

        AiDEXDiagnosticEvent.record(.scan, .started)

        let transport = AiDEXBluetoothProbe()
        let generation = activeGeneration
        transport.onEvent = { [weak self] event in
            self?.handle(event, generation: generation)
        }
        self.transport = transport
        transport.start()
    }

    public func stop(_ reason: AiDEXStopReason) {
        guard isActive else { return }
        finish(reason: reason)
    }

    /// The view calls this once a second while visible to check search and signal loss.
    public func tick() {
        guard isActive else { return }
        now = Date()
        if phase == .scanning, let scanStartedAt,
           ProcessInfo.processInfo.systemUptime - scanStartedAt >= 45
        {
            finish(reason: .notFound)
            return
        }
        guard var session, session.phase == .matched else { return }
        let disappeared = session.checkDisappearance(now: now)
        self.session = session
        if disappeared {
            finish(reason: .disappeared)
        }
    }

    private func handle(_ event: AiDEXProbeTransportEvent, generation: UUID) {
        guard generation == activeGeneration, isActive, var session else { return }

        switch event {
        case .scanningStarted:
            scanStartedAt = ProcessInfo.processInfo.systemUptime

        case let .unavailable(reason):
            session.markUnavailable(reason)
            self.session = nil
            latest = nil
            phase = .unavailable(reason)
            activeGeneration = UUID()
            teardownTransport()
            AiDEXDiagnosticEvent.record(.scan, .unavailable)

        case let .advertisement(peripheralID, localName, manufacturerData, receivedAt):
            let result = session.receive(
                peripheralID: peripheralID,
                localName: localName,
                manufacturerData: manufacturerData,
                at: receivedAt
            )
            self.session = session

            if result.matchedNow, !reportedMatch {
                reportedMatch = true
                AiDEXDiagnosticEvent.record(.match, .matched)
            }
            guard session.phase == .matched else { return }
            if phase != .matched {
                phase = .matched
            }

            if let issue = result.issue, reportedIssues.insert(issue).inserted {
                AiDEXDiagnosticEvent.record(.reading, issue.diagnosticOutcome)
            }

            if case let .accepted(reading)? = result.reading {
                latest = reading
                if !reportedReading {
                    reportedReading = true
                    AiDEXDiagnosticEvent.record(.reading, .present)
                }
            }
        }
    }

    private func finish(reason: AiDEXStopReason) {
        let hadMatch = reportedMatch
        if reason == .disappeared, hadMatch {
            AiDEXDiagnosticEvent.record(.match, .absent)
        } else if !hadMatch, !reportedNotMatched {
            reportedNotMatched = true
            AiDEXDiagnosticEvent.record(.match, .notMatched)
        }
        AiDEXDiagnosticEvent.record(.scan, reason == .notFound ? .timedOut : .cancelled)

        teardownTransport()
        session = nil
        latest = nil
        phase = .stopped(reason)
        activeGeneration = UUID()
    }

    private func teardownTransport() {
        transport?.onEvent = nil
        transport?.stop()
        transport = nil
    }
}
#endif

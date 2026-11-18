import Foundation

// MARK: - Common event contract

/// The cross-feature diagnostic event contract.
///
/// A feature posts `notificationName` with this `userInfo`:
///
///     schema: 1            (Int, must match `schemaVersion`)
///     feature: "ottai"     (String, must be registered below)
///     stage: "nfc"         (String, must be registered for that feature)
///     outcome: "started"   (String, must be registered for that feature)
///     attempt: 1           (optional Int, bounded)
///     count: 3             (optional Int, bounded)
///
/// The receiver never accepts free-form text, raw errors, identifiers, glucose
/// or treatment data. Names are allowlisted here, source-side, and validated
/// again before persistence. A future feature adds one entry to `features` and
/// gets the existing export for free; it does not implement export itself.
enum DiagnosticEventContract {
    static let notificationName = Notification.Name("com.trio.diagnostics.event")
    static let schemaVersion = 1

    static let exportSchema = "trio.export.diagnostics"
    static let exportSchemaVersion = 1

    struct Feature {
        let stages: Set<String>
        let outcomes: Set<String>
    }

    /// Add a feature here, not in `LogExport`.
    static let features: [String: Feature] = [
        "ottai": Feature(
            stages: [
                "nfc",
                "ble_match",
                "ble_non_match",
                "activation",
                "binding",
                "completion",
                "first_reading",
                "reconnect_grid"
            ],
            outcomes: [
                "started",
                "succeeded",
                "tag_detected",
                "failed",
                "cancelled",
                "unavailable",
                "matched",
                "not_matched",
                "present",
                "absent",
                "retried",
                "timed_out"
            ]
        ),
        "aidex": Feature(
            stages: [
                "scan",
                "match",
                "reading"
            ],
            outcomes: [
                "started",
                "unavailable",
                "cancelled",
                "timed_out",
                "matched",
                "not_matched",
                "absent",
                "present",
                "unsupported_frame",
                "checksum_mismatch",
                "reading_unavailable"
            ]
        ),
        "sibionics": Feature(
            stages: ["scan", "match", "connection", "service", "characteristic"],
            outcomes: ["started", "matched", "succeeded", "unavailable", "timed_out", "failed", "stopped"]
        ),
        "keep_alive": Feature(
            stages: ["audio", "reminder", "data"],
            outcomes: ["started", "stopped", "failed", "interrupted", "capped", "scheduled", "recovered"]
        )
    ]

    static var allowedFeatures: [String] { features.keys.sorted() }

    static func accepts(feature: String, stage: String, outcome: String) -> Bool {
        guard let registered = features[feature] else { return false }
        return registered.stages.contains(stage) && registered.outcomes.contains(outcome)
    }
}

/// One persisted event. Every field is bounded and allowlisted; there is no
/// free-form message field by design.
struct DiagnosticEvent: Codable, Equatable {
    let timestamp: Date
    let feature: String
    let stage: String
    let outcome: String
    let attempt: Int?
    let count: Int?

    static let maximumAttempt = 999
    static let maximumCount = 9_999

    /// Persisted/decoded events are untrusted: validate every field against
    /// the same source-side allowlist before exposing or exporting them.
    var isValid: Bool {
        guard DiagnosticEventContract.accepts(feature: feature, stage: stage, outcome: outcome) else {
            return false
        }
        if let attempt, !(0 ... Self.maximumAttempt).contains(attempt) { return false }
        if let count, !(0 ... Self.maximumCount).contains(count) { return false }
        return true
    }

    func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Bounded persistent store

/// Persists a small, time-bounded event log in `UserDefaults`, independent of
/// any device registration. Pairing events therefore survive an app relaunch
/// even though no `CGMManager` exists yet.
final class DiagnosticEventStore: @unchecked Sendable {
    static let shared = DiagnosticEventStore()

    static let defaultsKey = "Trio.DiagnosticEvents.v1"
    static let maximumEvents = 400
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let lock = NSLock()
    private let observerLock = NSLock()
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private var events: [DiagnosticEvent]
    private var observer: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.now = now
        events = Self.load(from: defaults)
        prune(at: now())
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    /// Installed once from the app entry point, before services or a device
    /// manager exist.
    func startObserving() {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: DiagnosticEventContract.notificationName,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.accept(notification.userInfo)
        }
    }

    func stopObserving() {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    @discardableResult
    func record(
        feature: String,
        stage: String,
        outcome: String,
        attempt: Int? = nil,
        count: Int? = nil,
        timestamp: Date? = nil
    ) -> Bool {
        guard DiagnosticEventContract.accepts(feature: feature, stage: stage, outcome: outcome) else {
            return false
        }
        let at = timestamp ?? now()
        let event = DiagnosticEvent(
            timestamp: at,
            feature: feature,
            stage: stage,
            outcome: outcome,
            attempt: attempt.map { min(max($0, 0), DiagnosticEvent.maximumAttempt) },
            count: count.map { min(max($0, 0), DiagnosticEvent.maximumCount) }
        )
        lock.lock()
        events.append(event)
        pruneLocked(at: now())
        saveLocked()
        lock.unlock()
        return true
    }

    func events(in window: DateInterval) -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
            .filter(\.isValid)
            .filter { window.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var allEvents: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter(\.isValid)
    }

    func removeAll() {
        lock.lock()
        events.removeAll()
        saveLocked()
        lock.unlock()
    }

    private func accept(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let schema = userInfo["schema"] as? Int,
              schema == DiagnosticEventContract.schemaVersion,
              let feature = userInfo["feature"] as? String,
              let stage = userInfo["stage"] as? String,
              let outcome = userInfo["outcome"] as? String
        else { return }
        record(
            feature: feature,
            stage: stage,
            outcome: outcome,
            attempt: userInfo["attempt"] as? Int,
            count: userInfo["count"] as? Int
        )
    }

    private func prune(at date: Date) {
        lock.lock()
        pruneLocked(at: date)
        saveLocked()
        lock.unlock()
    }

    private func pruneLocked(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        events.removeAll { $0.timestamp < cutoff }
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder.diagnosticStore.encode(events) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [DiagnosticEvent] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder.diagnosticStore.decode([DiagnosticEvent].self, from: data)
        else { return [] }
        return decoded.filter(\.isValid)
    }
}

private extension JSONEncoder {
    static let diagnosticStore: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let diagnosticStore: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

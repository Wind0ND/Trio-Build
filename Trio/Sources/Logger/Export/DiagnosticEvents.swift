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
        "medtrum": Feature(stages: ["automatic_mode", "delivery_guard"],
                           outcomes: ["available", "basal_only", "age_unknown", "no_active_session", "invalidated"]),
        "ottai": Feature(
            stages: [
                "nfc",
                "ble_match",
                "ble_non_match",
                "activation",
                "binding",
                "completion",
                "first_reading",
                "reconnect_grid", "transport", "forwarding"
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
                "timed_out", "received", "submitted"
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
        "privacy": Feature(
            stages: ["settings", "cover", "authentication", "lock", "activity", "journal", "recovery"],
            outcomes: ["changed", "succeeded", "failed", "reset", "enabled", "disabled", "published", "requested", "completed", "invoked"]
        ),
        "keep_alive": Feature(
            stages: ["audio", "reminder", "data", "source", "lifecycle", "recovery", "audio_minutes", "audio_starts", "cycle_delay_seconds", "missed_windows"],
            outcomes: ["started", "stopped", "failed", "interrupted", "capped", "scheduled", "recovered", "received", "stored", "background", "foreground", "requested", "completed", "timed_out", "reset", "overdue", "sampled"]
        ),
        "activity": Feature(stages: ["state", "lifecycle", "handoff"],
            outcomes: ["active", "stale", "ended", "dismissed", "unknown", "created", "updated", "deferred", "failed", "scheduled"]),
        "alerts": Feature(stages: ["plan", "trigger", "delivery", "cancel", "alarm"],
            outcomes: ["scheduled", "fired", "delivered", "cancelled", "stopped", "failed"]),
        "branding": Feature(stages: ["bundle"], outcomes: ["consistent", "mismatch"]),
        "app": Feature(stages: ["launch"], outcomes: ["started"])
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
    static let maximumEvents = 4000
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let lock = NSLock()
    private let observerLock = NSLock()
    private let defaults: UserDefaults
    private let notificationCenter: Foundation.NotificationCenter
    private let now: () -> Date
    private struct Page: Codable {
        let generation: UUID?
        let events: [DiagnosticEvent]
    }

    private static let tailKey = defaultsKey + ".tail"
    private static let pageSize = 64
    private var generation: UUID?
    private var tail: [DiagnosticEvent]
    private var events: [DiagnosticEvent]
    private var observer: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        notificationCenter: Foundation.NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.now = now
        let checkpoint = Self.loadCheckpoint(from: defaults)
        generation = checkpoint.generation
        let savedTail = defaults.data(forKey: Self.tailKey).flatMap {
            try? JSONDecoder.diagnosticStore.decode(Page.self, from: $0)
        }
        tail = savedTail?.generation == checkpoint.generation ? (savedTail?.events ?? []).filter(\.isValid) : []
        events = checkpoint.events.filter(\.isValid) + tail
        let storedCount = checkpoint.events.count + (savedTail?.events.count ?? 0)
        pruneLocked(at: now())
        if events.count != storedCount { checkpointLocked() }
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
        let currentDate = now()
        guard at >= currentDate.addingTimeInterval(-Self.retention) else { return true }
        lock.lock()
        events.append(event)
        tail.append(event)
        if tail.count >= Self.pageSize {
            pruneLocked(at: currentDate)
            checkpointLocked()
        } else if let data = try? JSONEncoder.diagnosticStore.encode(Page(generation: generation, events: tail)) {
            defaults.set(data, forKey: Self.tailKey)
        }
        lock.unlock()
        return true
    }

    func events(in window: DateInterval) -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        pruneForReadLocked()
        return events
            .filter(\.isValid)
            .filter { window.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var allEvents: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        pruneForReadLocked()
        return events.filter(\.isValid)
    }

    func removeAll() {
        lock.lock()
        events.removeAll()
        checkpointLocked()
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

    private func pruneForReadLocked() {
        let previousCount = events.count
        pruneLocked(at: now())
        if events.count < previousCount { checkpointLocked() }
    }

    private func pruneLocked(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        events.removeAll { $0.timestamp < cutoff }
        if events.count > Self.maximumEvents {
            // Reserve recent lifecycle/recovery evidence and failures independently of high-volume transport.
            // Both reservations are finite; this is bounded coverage, not a promise of a complete seven-day log.
            let critical = Set(events.indices.filter { index in
                let event = events[index]
                return ["failed", "timed_out", "mismatch"].contains(event.outcome)
                    || ["app", "branding"].contains(event.feature)
                    || (event.feature == "activity" && event.outcome != "updated")
            }.suffix(256))
            let evidence = Set(events.indices.filter { index in
                let event = events[index]
                return event.feature == "alerts" || event.stage == "recovery"
                    || (event.feature == "keep_alive" && ["audio", "reminder", "lifecycle"].contains(event.stage))
            }.suffix(1000))
            let protected = critical.union(evidence)
            var excess = events.count - Self.maximumEvents
            events = events.enumerated().compactMap { index, event in
                if excess > 0 && !protected.contains(index) { excess -= 1; return nil }
                return event
            }
            if excess > 0 { events.removeFirst(excess) }
        }
    }

    private func checkpointLocked() {
        let next = UUID()
        guard let data = try? JSONEncoder.diagnosticStore.encode(Page(generation: next, events: events)) else { return }
        // Write the new generation first. A crash before deleting the old tail cannot replay it.
        defaults.set(data, forKey: Self.defaultsKey)
        generation = next
        tail.removeAll(keepingCapacity: true)
        defaults.removeObject(forKey: Self.tailKey)
    }

    private static func loadCheckpoint(from defaults: UserDefaults) -> Page {
        guard let data = defaults.data(forKey: defaultsKey) else { return Page(generation: nil, events: []) }
        let decoder = JSONDecoder.diagnosticStore
        if let page = try? decoder.decode(Page.self, from: data) { return page }
        let legacy = (try? decoder.decode([DiagnosticEvent].self, from: data)) ?? []
        return Page(generation: nil, events: legacy)
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

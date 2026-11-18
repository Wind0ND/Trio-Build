import Foundation
import Testing

@testable import Trio

@Suite("Diagnostic Event Tests", .serialized) struct DiagnosticEventTests {
    private static func defaults() -> UserDefaults {
        let name = "DiagnosticEventTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Only registered feature/stage/outcome triples are accepted") func allowlist() {
        let store = DiagnosticEventStore(defaults: Self.defaults(), now: { Self.start })
        #expect(!store.record(feature: "ottai", stage: "nfc", outcome: "raw-error"))
        #expect(!store.record(feature: "unknown", stage: "nfc", outcome: "started"))
        #expect(!store.record(feature: "ottai", stage: "unknown", outcome: "started"))
        #expect(store.record(feature: "ottai", stage: "nfc", outcome: "started"))
        #expect(store.allEvents.count == 1)
    }

    @Test("The AiDEX feature accepts only its finite scan/match/reading events") func aidexAllowlist() {
        let accepted: [(String, String)] = [
            ("scan", "started"),
            ("scan", "unavailable"),
            ("scan", "cancelled"),
            ("scan", "timed_out"),
            ("match", "matched"),
            ("match", "not_matched"),
            ("match", "absent"),
            ("reading", "present"),
            ("reading", "unsupported_frame"),
            ("reading", "checksum_mismatch"),
            ("reading", "reading_unavailable")
        ]
        for (stage, outcome) in accepted {
            #expect(DiagnosticEventContract.accepts(feature: "aidex", stage: stage, outcome: outcome))
        }
        #expect(!DiagnosticEventContract.accepts(feature: "aidex", stage: "nfc", outcome: "started"))
        #expect(!DiagnosticEventContract.accepts(feature: "aidex", stage: "scan", outcome: "succeeded"))
        #expect(!DiagnosticEventContract.accepts(feature: "aidex", stage: "reading", outcome: "succeeded"))

        let store = DiagnosticEventStore(defaults: Self.defaults(), now: { Self.start })
        #expect(store.record(feature: "aidex", stage: "scan", outcome: "started"))
        #expect(store.record(feature: "aidex", stage: "reading", outcome: "present", count: 99_999))
        #expect(store.allEvents.count == 2)
        #expect(store.allEvents.last?.count == DiagnosticEvent.maximumCount)
    }

    @Test("GS1 connection results can enter the diagnostic store") func sibionicsDiagnostics() {
        let store = DiagnosticEventStore(defaults: Self.defaults(), now: { Self.start })
        #expect(store.record(feature: "sibionics", stage: "connection", outcome: "timed_out"))
        #expect(store.record(feature: "sibionics", stage: "service", outcome: "succeeded"))
        #expect(store.record(feature: "sibionics", stage: "characteristic", outcome: "failed"))
        #expect(!store.record(feature: "sibionics", stage: "reading", outcome: "started"))
        #expect(store.allEvents.count == 3)
    }

    @Test("Keep-alive diagnostic transitions are allowed") func keepAliveDiagnostics() {
        let store = DiagnosticEventStore(defaults: Self.defaults(), now: { Self.start })
        #expect(store.record(feature: "keep_alive", stage: "audio", outcome: "interrupted"))
        #expect(store.record(feature: "keep_alive", stage: "reminder", outcome: "scheduled"))
        #expect(!store.record(feature: "keep_alive", stage: "audio", outcome: "raw error"))
        #expect(store.allEvents.count == 2)
    }

    @Test("Bounded counters are clamped and free-form payloads cannot enter") func boundedCounters() {
        let store = DiagnosticEventStore(defaults: Self.defaults(), now: { Self.start })
        #expect(store.record(feature: "ottai", stage: "nfc", outcome: "started", attempt: -9, count: 1_000_000))
        let event = store.allEvents.first
        #expect(event?.attempt == 0)
        #expect(event?.count == DiagnosticEvent.maximumCount)
    }

    @Test("The store keeps the newest events and drops events older than seven days") func pruning() {
        let store = DiagnosticEventStore(defaults: Self.defaults(), now: { Self.start })
        store.record(
            feature: "ottai",
            stage: "nfc",
            outcome: "failed",
            timestamp: Self.start.addingTimeInterval(-DiagnosticEventStore.retention - 1)
        )
        #expect(store.allEvents.isEmpty)

        for index in 0 ..< (DiagnosticEventStore.maximumEvents + 5) {
            store.record(
                feature: "ottai",
                stage: "nfc",
                outcome: "started",
                count: index,
                timestamp: Self.start.addingTimeInterval(Double(index))
            )
        }
        #expect(store.allEvents.count == DiagnosticEventStore.maximumEvents)
        #expect(store.allEvents.first?.count == 5)
        #expect(store.allEvents.last?.count == DiagnosticEventStore.maximumEvents + 4)
    }

    @Test("Events persist across store instances so pre-registration pairing survives a relaunch") func persistence() {
        let defaults = Self.defaults()
        let first = DiagnosticEventStore(defaults: defaults, now: { Self.start })
        #expect(first.record(feature: "ottai", stage: "activation", outcome: "started", attempt: 1))
        #expect(first.record(feature: "ottai", stage: "first_reading", outcome: "present"))

        let relaunched = DiagnosticEventStore(defaults: defaults, now: { Self.start.addingTimeInterval(60) })
        #expect(relaunched.allEvents == first.allEvents)
        #expect(relaunched.allEvents.map(\.stage) == ["activation", "first_reading"])
    }

    @Test("The notification contract is validated before persistence") func notificationContract() {
        // Isolated center: the app's shared store must not see test events.
        let center = NotificationCenter()
        let store = DiagnosticEventStore(
            defaults: Self.defaults(),
            now: { Self.start },
            notificationCenter: center
        )
        store.startObserving()
        defer { store.stopObserving() }

        center.post(
            name: DiagnosticEventContract.notificationName,
            object: nil,
            userInfo: [
                "schema": 1,
                "feature": "ottai",
                "stage": "nfc",
                "outcome": "started",
                "attempt": 2
            ]
        )
        #expect(store.allEvents.count == 1)
        #expect(store.allEvents.first?.attempt == 2)

        center.post(
            name: DiagnosticEventContract.notificationName,
            object: nil,
            userInfo: [
                "schema": 1,
                "feature": "ottai",
                "stage": "nfc",
                "outcome": "sensor at AA:BB:CC says nope"
            ]
        )
        #expect(store.allEvents.count == 1)

        center.post(
            name: DiagnosticEventContract.notificationName,
            object: nil,
            userInfo: [
                "schema": 2,
                "feature": "ottai",
                "stage": "nfc",
                "outcome": "started"
            ]
        )
        #expect(store.allEvents.count == 1)
    }

    @Test("Window filtering is inclusive and exported in time order") func windowFiltering() {
        let store = DiagnosticEventStore(defaults: Self.defaults(), now: { Self.start })
        store.record(feature: "ottai", stage: "nfc", outcome: "started", timestamp: Self.start.addingTimeInterval(-120))
        store.record(feature: "ottai", stage: "nfc", outcome: "succeeded", timestamp: Self.start.addingTimeInterval(-60))
        store.record(feature: "ottai", stage: "nfc", outcome: "failed", timestamp: Self.start.addingTimeInterval(-10))

        let window = DateInterval(start: Self.start.addingTimeInterval(-90), end: Self.start)
        #expect(store.events(in: window).map(\.outcome) == ["succeeded", "failed"])
    }

    @Test("Restored stores reject malformed fields and unexpected strings") func restoredValidation() {
        let defaults = Self.defaults()
        let valid = DiagnosticEvent(
            timestamp: Self.start.addingTimeInterval(-60),
            feature: "ottai",
            stage: "nfc",
            outcome: "started",
            attempt: 1,
            count: nil
        )
        let malformed = [
            DiagnosticEvent(
                timestamp: Self.start.addingTimeInterval(-50),
                feature: "unexpected-feature",
                stage: "nfc",
                outcome: "started",
                attempt: nil,
                count: nil
            ),
            DiagnosticEvent(
                timestamp: Self.start.addingTimeInterval(-40),
                feature: "ottai",
                stage: "made_up_stage",
                outcome: "started",
                attempt: nil,
                count: nil
            ),
            DiagnosticEvent(
                timestamp: Self.start.addingTimeInterval(-30),
                feature: "ottai",
                stage: "nfc",
                outcome: "sensor at AA:BB:CC says nope",
                attempt: nil,
                count: nil
            ),
            DiagnosticEvent(
                timestamp: Self.start.addingTimeInterval(-20),
                feature: "ottai",
                stage: "nfc",
                outcome: "started",
                attempt: 1_000,
                count: nil
            ),
            DiagnosticEvent(
                timestamp: Self.start.addingTimeInterval(-10),
                feature: "ottai",
                stage: "nfc",
                outcome: "started",
                attempt: nil,
                count: -1
            ),
            DiagnosticEvent(
                timestamp: Self.start.addingTimeInterval(-DiagnosticEventStore.retention - 1),
                feature: "ottai",
                stage: "nfc",
                outcome: "started",
                attempt: nil,
                count: nil
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try? encoder.encode([valid] + malformed), forKey: DiagnosticEventStore.defaultsKey)

        let restored = DiagnosticEventStore(defaults: defaults, now: { Self.start })
        #expect(restored.allEvents == [valid])
        #expect(restored.allEvents.allSatisfy { $0.isValid })
        #expect(restored.events(in: DateInterval(start: Self.start.addingTimeInterval(-120), end: Self.start)) == [valid])
    }
}

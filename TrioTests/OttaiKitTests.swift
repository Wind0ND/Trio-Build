import Foundation
@testable import OttaiKit
import Testing

@Suite("Ottai Wake Target Tests") struct OttaiWakeTargetTests {
    private static func candidate(_ mac: String, rssi: Int? = nil) -> OttaiSensorCandidate {
        OttaiSensorCandidate(mac: mac, rssi: rssi)
    }

    @Test("A QR-selected MAC is matched case- and separator-insensitively") func matchesNormalizedTarget() {
        let candidates = [
            Self.candidate("AA:BB:CC:DD:EE:02", rssi: -70),
            Self.candidate("aa-bb-cc-dd-ee-01", rssi: -55)
        ]
        let match = OttaiWakeTargetMatcher.match(targetMAC: "AA:BB:CC:DD:EE:01", candidates: candidates)
        #expect(match?.mac == "aa-bb-cc-dd-ee-01")
        #expect(match?.rssi == -55)
    }

    @Test("A different advertiser never counts as the woken target") func rejectsWrongTarget() {
        let candidates = [Self.candidate("AA:BB:CC:DD:EE:02")]
        #expect(OttaiWakeTargetMatcher.match(targetMAC: "AA:BB:CC:DD:EE:01", candidates: candidates) == nil)
        #expect(OttaiWakeTargetMatcher.match(targetMAC: nil, candidates: candidates) == nil)
        #expect(OttaiWakeTargetMatcher.match(targetMAC: "not a mac", candidates: candidates) == nil)
    }

    @Test("The no-QR picker only offers eligible advertisers") func filtersRetiredCandidates() {
        let candidates = [
            Self.candidate("AA:BB:CC:DD:EE:01"),
            Self.candidate("AA:BB:CC:DD:EE:02")
        ]
        let eligible = OttaiWakeTargetMatcher.eligible(candidates, excluding: ["aa:bb:cc:dd:ee:02"])
        #expect(eligible.map(\.mac) == ["AA:BB:CC:DD:EE:01"])
    }
}

@Suite("Ottai Persisted State Tests") struct OttaiPersistedStateTests {
    private static let activatedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static func device(mac: String = "AA:BB:CC:DD:EE:01") -> DeviceInfo {
        DeviceInfo(
            mac: mac,
            serialNo: "SYNTHETIC-SERIAL",
            batchNo: "SYNTHETIC-BATCH",
            deviceType: "M8",
            deviceVersion: "1.8",
            coefficients: [1, 0, 0, 0, 1, 1, 1],
            k: 1,
            b: 1,
            produceTime: activatedAt.addingTimeInterval(-86_400),
            expireTime: activatedAt.addingTimeInterval(365 * 86_400),
            activeDuration: 10 * 86_400,
            preheatDuration: 3_600
        )
    }

    private static func record(mac: String) -> OttaiSensorRecord {
        OttaiSensorRecord(
            deviceInfo: device(mac: mac),
            keyGroup: OttaiKeyGroup(raw: Data(repeating: 0x42, count: 6)),
            activatedAt: activatedAt
        )
    }

    private static func writeLegacy(
        _ records: [OttaiSensorRecord],
        paths: OttaiSensorHistoryPaths
    ) throws {
        try FileManager.default.createDirectory(at: paths.legacyDirectory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: records.map(\.rawValue),
            format: .binary,
            options: 0
        )
        try data.write(to: paths.legacyFileURL, options: .atomic)
    }

    @Test("Legacy active sensor migrates only its own record from the old plist") func legacyActiveSensorMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OttaiSensorHistoryPaths(root: root)
        let active = Self.record(mac: "AA:BB:CC:DD:EE:01")
        let unrelatedLegacy = Self.record(mac: "AA:BB:CC:DD:EE:99")
        let modernUnrelated = Self.record(mac: "AA:BB:CC:DD:EE:02")

        // Build 19: rawState only knows activeMAC; the full record/key lives in
        // the old shared file, alongside an unrelated sensor's record.
        try Self.writeLegacy([unrelatedLegacy, active], paths: paths)
        OttaiSensorHistoryStore.save([modernUnrelated], paths: paths)

        let loaded = OttaiSensorHistoryStore.load(paths: paths)
        var migrated = OttaiSensorHistoryStore.migrateActiveSensor(
            activeMAC: active.mac,
            existing: loaded,
            paths: paths
        )
        OttaiSensorHistoryStore.save(migrated, paths: paths)
        let after = OttaiSensorHistoryStore.load(paths: paths)

        #expect(after.map(\.mac).sorted() == [active.mac, modernUnrelated.mac].sorted())
        #expect(!after.contains { $0.mac == unrelatedLegacy.mac })
        let restoredActive = after.first { $0.mac == active.mac }
        #expect(restoredActive?.activatedAt == Self.activatedAt)
        #expect(restoredActive?.keyGroup.raw == Data(repeating: 0x42, count: 6))
        #expect(FileManager.default.fileExists(atPath: paths.legacyFileURL.path))
        #expect(FileManager.default.fileExists(atPath: paths.fileURL.path))

        // Retried construction does not duplicate the migrated record.
        migrated = OttaiSensorHistoryStore.migrateActiveSensor(activeMAC: active.mac, existing: after, paths: paths)
        #expect(migrated.count == after.count)

        // Without an explicit activeMAC, never infer one from a random record.
        let noActive = OttaiSensorHistoryStore.migrateActiveSensor(activeMAC: nil, existing: loaded, paths: paths)
        #expect(noActive.map(\.mac) == loaded.map(\.mac))
    }

    @Test("Old keys decode without inventing a newly paired sensor") func absentSensorStaysAbsent() {
        let raw: [String: Any] = [
            "latestReadingTimestamp": Self.activatedAt,
            "lastGridSequence": 42,
            "latestElapsedSeconds": 123.0,
            "sensorFaultKind": "obsolete",
            "sensorFaultState": 4,
            "telemetryTier": "minimal",
            "telemetryDisclosureShown": true
        ]
        let state = OttaiCGMManagerState(rawValue: raw)
        #expect(state != nil)
        #expect(state?.mac == nil)
        #expect(state?.sensors.current() == nil)
        #expect(state?.lastGridSequence == 42)
        #expect(state?.latestElapsedSeconds == 123)

        let roundTrip = state?.rawValue
        #expect(roundTrip?["lastGridSequence"] as? Int == 42)
        #expect(roundTrip?["sensorFaultKind"] as? String == "obsolete")
        #expect(roundTrip?["telemetryTier"] as? String == "minimal")
        #expect(roundTrip?["telemetryDisclosureShown"] as? Bool == true)
    }
}

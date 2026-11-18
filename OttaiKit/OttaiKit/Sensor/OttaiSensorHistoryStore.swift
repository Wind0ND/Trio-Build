//
//  OttaiSensorHistoryStore.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// File locations for the Ottai-owned history mirror. Injectable so the
/// migration can be exercised against temporary directories.
struct OttaiSensorHistoryPaths {
    let root: URL

    static var live: OttaiSensorHistoryPaths {
        OttaiSensorHistoryPaths(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    var directory: URL { root.appendingPathComponent("ottai", isDirectory: true) }
    var fileURL: URL { directory.appendingPathComponent("ottai_sensor_history.plist") }
    var legacyDirectory: URL { root.appendingPathComponent("syai", isDirectory: true) }
    var legacyFileURL: URL { legacyDirectory.appendingPathComponent("syai_sensor_history.plist") }
}

/// Durable mirror of `OttaiSensorStore.records`, written to a plist file next
/// to `OttaiLogger`'s log files (`Documents/ottai/`). `OttaiCGMManagerState`'s
/// own `rawState` is deleted wholesale by the host app when a CGM manager is
/// removed, so sensor history would otherwise be lost every time a user swaps
/// CGMs; this file survives that and is merged back in on the next
/// `OttaiCGMManager` construction.
enum OttaiSensorHistoryStore {
    private static let fileManager = FileManager.default
    private static let logger = OttaiLogger(category: "SensorHistoryStore")

    static func load(paths: OttaiSensorHistoryPaths = .live) -> [OttaiSensorRecord] {
        guard let data = try? Data(contentsOf: paths.fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let recordsRaw = plist as? [[String: Any]] else { return [] }
        return recordsRaw.compactMap(OttaiSensorRecord.init(rawValue:))
    }

    static func save(_ records: [OttaiSensorRecord], paths: OttaiSensorHistoryPaths = .live) {
        // This file is the only surviving copy of the active sensor's record
        // once the host app deletes rawState, so a silent write failure means
        // an unpairable sensor with no trace of why.
        if !fileManager.fileExists(atPath: paths.directory.path) {
            do {
                try fileManager.createDirectory(at: paths.directory, withIntermediateDirectories: true)
            } catch {
                logger.error("failed to create history directory: \(error.localizedDescription)")
            }
        }
        let recordsRaw = records.map(\.rawValue)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: recordsRaw, format: .binary, options: 0)
            try data.write(to: paths.fileURL, options: .atomic)
        } catch {
            logger.error("failed to save sensor history (\(records.count) records): \(error.localizedDescription)")
        }
    }

    /// Build 19 wrote Ottai history into SyaiKit's shared `Documents/syai/`
    /// file and persisted only `activeMAC` (not the sensor record/key) in the
    /// manager's rawState. Pull back exactly the active record, never the whole
    /// legacy file: that file may also contain unrelated Syai sensors, and
    /// guessing an active one from it would silently attach the wrong sensor.
    ///
    /// The legacy file is read-only here. If it is missing/corrupt this returns
    /// `existing` unchanged, and the next construction retries.
    static func migrateActiveSensor(
        activeMAC: String?,
        existing: [OttaiSensorRecord],
        paths: OttaiSensorHistoryPaths = .live
    ) -> [OttaiSensorRecord] {
        guard let normalized = normalizedMAC(activeMAC),
              !existing.contains(where: { normalizedMAC($0.mac) == normalized })
        else { return existing }

        let legacy = loadLegacy(paths: paths)
        guard let active = legacy.first(where: { normalizedMAC($0.mac) == normalized }) else {
            logger.info("no legacy record for the active MAC; will retry on the next construction")
            return existing
        }
        logger.info("migrated the active sensor record from the legacy history file")
        return existing + [active]
    }

    /// Read-only legacy mirror. Kept separate so the migration can prove it
    /// never writes to or deletes the old shared file.
    static func loadLegacy(paths: OttaiSensorHistoryPaths = .live) -> [OttaiSensorRecord] {
        guard let data = try? Data(contentsOf: paths.legacyFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let recordsRaw = plist as? [[String: Any]] else { return [] }
        return recordsRaw.compactMap(OttaiSensorRecord.init(rawValue:))
    }

    private static func normalizedMAC(_ mac: String?) -> String? {
        guard let mac else { return nil }
        let normalized = mac.uppercased().filter(\.isHexDigit)
        return normalized.isEmpty ? nil : normalized
    }
}

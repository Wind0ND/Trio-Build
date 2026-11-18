//
//  OttaiWakeTargetMatcher.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Pure matching rules for the NFC wake flow. Kept out of the view model so the
/// "which advertiser is the one I woke?" decision is testable without CoreNFC or
/// CoreBluetooth.
public enum OttaiWakeTargetMatcher {
    /// MACs arrive from the QR text, the accessory, and persisted history with
    /// different case and separators. Compare the hex payload only.
    public static func normalized(_ mac: String) -> String {
        mac.uppercased().filter(\.isHexDigit)
    }

    /// The QR-selected (or user-selected) target must actually appear in BLE
    /// discovery before the UI may call it awake.
    public static func match(
        targetMAC: String?,
        candidates: [OttaiSensorCandidate]
    ) -> OttaiSensorCandidate? {
        guard let targetMAC else { return nil }
        let target = normalized(targetMAC)
        guard !target.isEmpty else { return nil }
        return candidates.first { normalized($0.mac) == target }
    }

    /// A picker may only offer sensors that are not already known/refused.
    public static func eligible(
        _ candidates: [OttaiSensorCandidate],
        excluding excludedMACs: Set<String>
    ) -> [OttaiSensorCandidate] {
        let excluded = Set(excludedMACs.map(normalized))
        return candidates.filter { !excluded.contains(normalized($0.mac)) }
    }
}

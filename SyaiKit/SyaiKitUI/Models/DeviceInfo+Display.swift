//
//  DeviceInfo+Display.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SyaiKit

extension DeviceInfo {
    /// `X1`/`Syai Tag` are the global products. A mainland Ottai sensor
    /// reports `M8`, so a brand-aware caller names it instead of pretending it
    /// is a Syai device.
    func productName(ottai: Bool) -> String {
        if ottai {
            return deviceType.isEmpty ? "Ottai" : "Ottai \(deviceType)"
        }
        return deviceType == "X1" ? "Syai Ultra" : "Syai Tag"
    }

    var productName: String { productName(ottai: false) }
}

//
//  DeviceInfo+Display.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import OttaiKit

extension DeviceInfo {
    /// `X1`/`Ottai Tag` are the global products. A mainland Ottai sensor
    /// reports `M8`, so a brand-aware caller names it instead of pretending it
    /// is a Ottai device.
    func productName(ottai: Bool) -> String {
        if ottai {
            return deviceType.isEmpty ? "Ottai" : "Ottai \(deviceType)"
        }
        return deviceType == "X1" ? "Ottai Ultra" : "Ottai Tag"
    }

    var productName: String { productName(ottai: false) }
}

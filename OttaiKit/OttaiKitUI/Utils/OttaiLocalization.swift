//
//  OttaiLocalization.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

extension Bundle {
    /// The UI framework's own bundle. New Ottai-only pairing copy lives in
    /// `OttaiKitUI.xcstrings` here, not in the host app's catalog.
    static var ottaiUI: Bundle { Bundle(for: OttaiUIController.self) }
}

/// Resolve an OttaiKitUI-local string explicitly from the UI framework bundle.
/// Use this only for strings that are new to this driver; shared/host strings
/// keep using the app catalog so their existing translations stay put.
func OttaiLocalizedString(_ key: String, comment: String) -> String {
    NSLocalizedString(
        key,
        bundle: .ottaiUI,
        value: key,
        comment: comment
    )
}

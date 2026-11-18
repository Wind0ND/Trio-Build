//
//  OttaiLocalization.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

extension Bundle {
    /// The UI framework's own bundle, used by `Resources/Localizable.xcstrings`.
    static var ottaiUI: Bundle { Bundle(for: OttaiUIController.self) }
}

/// Resolve an OttaiKitUI-local string explicitly from the UI framework bundle.
func OttaiLocalizedString(_ key: String, comment: String) -> String {
    NSLocalizedString(
        key,
        bundle: .ottaiUI,
        value: key,
        comment: comment
    )
}

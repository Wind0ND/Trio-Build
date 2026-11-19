import Foundation

public enum PrivacyPalettePreset: String, CaseIterable, Identifiable, Sendable {
    case quiet, balanced, mist
    public var id: String { rawValue }

    public var colors: [PrivacyColor] {
        let values: [UInt32]
        switch self {
        case .quiet: values = [0x7B63A3, 0x5375A9, 0x508165, 0x7C834A, 0xA16D40, 0xAC5853]
        case .balanced: values = [0x8B6FBA, 0x5B84C2, 0x5B9574, 0x8D9654, 0xBB7C46, 0xC5605A]
        case .mist: values = [0x947EAF, 0x7395B8, 0x739786, 0xA0A174, 0xB18B6A, 0xB27D7A]
        }
        return values.map(PrivacyColor.init(hex:))
    }
}

public enum PrivacyMeterStyle: String, CaseIterable, Identifiable, Sendable {
    case history, referenceFive
    public var id: String { rawValue }
    public static let referenceHeight = 5.0 / 12

    public static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: PrivacyPreference.meterStyleKey).flatMap(Self.init(rawValue:)) ?? .history
    }
}

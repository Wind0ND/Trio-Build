import Foundation

public enum PrivacyPalettePreset: String, CaseIterable, Identifiable, Sendable {
    case quiet, balanced, mist, separated, gold, soft
    public var id: String { rawValue }

    public var colors: [PrivacyColor] {
        let values: [UInt32]
        switch self {
        case .quiet: values = [0x7B63A3, 0x5375A9, 0x508165, 0x7C834A, 0xA16D40, 0xAC5853]
        case .balanced: values = [0x8B6FBA, 0x5B84C2, 0x5B9574, 0x8D9654, 0xBB7C46, 0xC5605A]
        case .mist: values = [0x947EAF, 0x7395B8, 0x739786, 0xA0A174, 0xB18B6A, 0xB27D7A]
        case .separated: values = [0x7B63A3, 0x4B70AE, 0x3E8C6A, 0xB5A262, 0xB5784B, 0xB45C6B]
        case .gold: values = [0x7B63A3, 0x5375A9, 0x508165, 0xB1A26B, 0xA16D40, 0xAC5853]
        case .soft: values = [0x8F73AB, 0x6588B5, 0x62A195, 0xC5B883, 0xBD8B6A, 0xBD7891]
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

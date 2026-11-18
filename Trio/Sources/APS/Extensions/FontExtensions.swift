import SwiftUI

extension Font.Weight {
    var displayName: String {
        switch self {
        case .ultraLight: return String(localized: "font.label.ultra-light", defaultValue: "Ultra Light")
        case .light: return String(localized: "font.label.light", defaultValue: "Light")
        case .regular: return String(localized: "font.label.regular", defaultValue: "Regular")
        case .medium: return String(localized: "Medium")
        case .semibold: return String(localized: "font.label.semibold", defaultValue: "Semibold")
        case .bold: return String(localized: "font.label.bold", defaultValue: "Bold")
        case .heavy: return String(localized: "font.label.heavy", defaultValue: "Heavy")
        case .black: return String(localized: "font.label.black", defaultValue: "Black")
        default: return String(localized: "Unknown")
        }
    }

    private static let stringToFontWeight: [String: Font.Weight] = [
        "ultraLight": .ultraLight,
        "thin": .thin,
        "light": .light,
        "regular": .regular,
        "medium": .medium,
        "semibold": .semibold,
        "bold": .bold,
        "heavy": .heavy,
        "black": .black
    ]

    private static let fontWeightToString: [Font.Weight: String] = [
        .ultraLight: "ultraLight",
        .thin: "thin",
        .light: "light",
        .regular: "regular",
        .medium: "medium",
        .semibold: "semibold",
        .bold: "bold",
        .heavy: "heavy",
        .black: "black"
    ]

    /// Initialize `Font.Weight` from a string
    static func fromString(_ string: String) -> Font.Weight {
        stringToFontWeight[string] ?? .regular // Default fallback
    }

    /// Convert `Font.Weight` to a string
    var asString: String {
        Font.Weight.fontWeightToString[self] ?? "regular" // Default fallback
    }
}

extension Font.Width {
    var displayName: String {
        switch self {
        case .condensed: return String(localized: "font.label.condensed", defaultValue: "Condensed")
        case .expanded: return String(localized: "Expanded")
        case .compressed: return String(localized: "font.label.compressed", defaultValue: "Compressed")
        case .standard: return String(localized: "Standard")
        default: return String(localized: "Unknown")
        }
    }

    private static let stringToFontWidth: [String: Font.Width] = [
        "compressed": .compressed,
        "condensed": .condensed,
        "standard": .standard,
        "expanded": .expanded
    ]

    private static let fontWidthToString: [Font.Width: String] = [
        .compressed: "compressed",
        .condensed: "condensed",
        .standard: "standard",
        .expanded: "expanded"
    ]

    /// Initialize `Font.Width` from a string
    static func fromString(_ string: String) -> Font.Width {
        stringToFontWidth[string] ?? .standard // Default fallback
    }

    /// Convert `Font.Width` to a string
    var asString: String {
        Font.Width.fontWidthToString[self] ?? "standard" // Default fallback
    }
}

import Foundation

/// Thin adapter between the existing icon picker and the separate branding catalog.
extension Icon_ {
    static var primaryAssetName: String {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        return primary?["CFBundleIconName"] as? String ?? "trioBlack"
    }

    var assetName: String { self == .primary ? Self.primaryAssetName : rawValue }

    static var availableIcons: [Self] {
        allCases.filter { $0 == .primary || $0.rawValue != primaryAssetName }
    }

    static func resolvedIcon(named name: String?) -> Self {
        guard let name, name != primaryAssetName else { return .primary }
        return Self(rawValue: name) ?? .primary
    }

    var displayName: String {
        let key: String
        switch assetName {
        case "hiroSleepCat": key = "Sleeping cat"
        case "hiroRoundCat": key = "Round-faced cat"
        case "hiroShiba": key = "Shiba Inu"
        case "hiroSpaniel": key = "Floppy-eared dog"
        case "hiroCorgi": key = "Corgi"
        default:
            var words = ""
            for character in assetName {
                if character.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(character)
            }
            return words.prefix(1).capitalized + words.dropFirst()
        }
        return NSLocalizedString(key, tableName: "HiroBranding", bundle: .main, value: key, comment: "App icon name")
    }
}

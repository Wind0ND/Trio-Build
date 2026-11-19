import Foundation

public enum PrivacyPreference {
    public static let changed = Notification.Name("com.trio.privacy.changed")
    public static let displayKey = "privacy.waveform.enabled"
    public static let alertsKey = "privacy.alerts.enabled"
    public static let boundariesKey = "privacy.color.boundaries"
    public static let coverKey = "privacy.cover.thumbnail"
    public static let biometricsKey = "privacy.lock.biometrics"
    public static let patternTraceKey = "privacy.lock.patternTrace"
    public static let paletteKey = "privacy.display.palette"
    public static let meterStyleKey = "privacy.display.meterStyle"

    public static var displayEnabled: Bool { UserDefaults.standard.bool(forKey: displayKey) }
    public static var alertsEnabled: Bool { UserDefaults.standard.bool(forKey: alertsKey) }

    public static func notifyChanged() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    public static func record(stage: String, outcome: String) {
        NotificationCenter.default.post(
            name: Notification.Name("com.trio.diagnostics.event"), object: nil,
            userInfo: ["schema": 1, "feature": "privacy", "stage": stage, "outcome": outcome]
        )
    }
}

public struct PrivacyColor: Codable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(hex: UInt32) {
        red = Double((hex >> 16) & 255) / 255
        green = Double((hex >> 8) & 255) / 255
        blue = Double(hex & 255) / 255
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let palette: [Self] = [0x6D28D9, 0x3B82F6, 0x22C55E, 0xB8DB55, 0xFB923C, 0xEF4444]
        .map(Self.init(hex:))
    // Public activity presentation has its own quieter colors; alarm accents stay unchanged.
    public static let displayPalette = PrivacyPalettePreset.quiet.colors
    public static let unknown = Self(hex: 0x9CA3AF)

    public func blended(with other: Self, amount: Double) -> Self {
        let amount = min(1, max(0, amount))
        return Self(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}

public struct PrivacyPalette: Sendable {
    public static let defaultBoundaries: [Double] = [3, 4, 6, 8, 12]
    public let boundaries: [Double]
    public let preset: PrivacyPalettePreset

    public init(boundaries: [Double] = defaultBoundaries, preset: PrivacyPalettePreset = .quiet) {
        self.boundaries = Self.isValid(boundaries) ? boundaries : Self.defaultBoundaries
        self.preset = preset
    }

    public static func isValid(_ values: [Double]) -> Bool {
        values.count == 5 && values.allSatisfy { $0.isFinite && (1 ... 30).contains($0) }
            && zip(values, values.dropFirst()).allSatisfy { pair in pair.1 - pair.0 >= 0.5 }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> Self {
        Self(
            boundaries: defaults.array(forKey: PrivacyPreference.boundariesKey) as? [Double] ?? defaultBoundaries,
            preset: defaults.string(forKey: PrivacyPreference.paletteKey).flatMap(PrivacyPalettePreset.init(rawValue:)) ?? .quiet
        )
    }

    public func color(mgDL: Double?) -> PrivacyColor {
        guard let mgDL, mgDL.isFinite, mgDL > 0 else { return .unknown }
        let value = mgDL / 18
        let colors = preset.colors
        for (index, boundary) in boundaries.enumerated() {
            let halfWidth = 0.15
            if abs(value - boundary) < halfWidth {
                return colors[index].blended(
                    with: colors[index + 1],
                    amount: (value - boundary + halfWidth) / (2 * halfWidth)
                )
            }
            if value < boundary { return colors[index] }
        }
        return colors[5]
    }
}

public struct PrivacyReading: Sendable {
    public let mgDL: Double
    public let date: Date

    public init(mgDL: Double, date: Date) {
        self.mgDL = mgDL
        self.date = date
    }
}

public struct PrivacyActivityState: Codable, Hashable, Sendable {
    public let heights: [Double?]
    public let color: PrivacyColor
    public let measuredAt: Date?
    public let recoveredAt: Date?
    public private(set) var cover: Data?
    // Optional string keeps old snapshots decodable and unknown future styles harmless.
    public private(set) var meterStyle: String?
    private let recentHeights: [Double]?

    public init(readings: [PrivacyReading], now: Date, palette: PrivacyPalette = .init(), cover: Data? = nil, recoveredAt: Date? = nil, meterStyle: PrivacyMeterStyle = .history) {
        self.meterStyle = meterStyle == .history ? nil : meterStyle.rawValue
        // A future or invalid reading cannot become the color/freshness anchor.
        let valid = readings.filter { $0.mgDL.isFinite && $0.mgDL > 0 && $0.mgDL <= 1000 && $0.date <= now }
            .sorted { $0.date > $1.date }
        var seenDates = Set<Date>()
        recentHeights = valid.filter { seenDates.insert($0.date).inserted }.prefix(5).reversed().map {
            min(1, max(0.12, $0.mgDL / (12 * 18)))
        }
        measuredAt = valid.first?.date
        // Only a validated current-grid receipt may extend presentation. Arbitrary old history is not freshened.
        if let recoveredAt, let measuredAt, recoveredAt >= measuredAt, recoveredAt <= now,
           recoveredAt.timeIntervalSince(measuredAt) <= 300 {
            self.recoveredAt = recoveredAt
        } else {
            self.recoveredAt = nil
        }
        color = palette.color(mgDL: valid.first?.mgDL)
        self.cover = cover.flatMap { $0.count <= 1200 ? $0 : nil }
        guard let latest = valid.first else {
            heights = Array(repeating: nil, count: 6)
            return
        }
        // Keep five-minute gaps visible rather than packing old readings together.
        heights = (0 ..< 6).reversed().map { slot in
            let target = latest.date.addingTimeInterval(-Double(slot) * 300)
            let sample = valid.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
            guard let sample, abs(sample.date.timeIntervalSince(target)) < 150 else { return nil }
            return min(1, max(0.12, sample.mgDL / (12 * 18)))
        }
    }

    // Five-minute readings get one minute of presentation grace; this never refreshes measurement age.
    public var staleDate: Date { (recoveredAt ?? measuredAt)?.addingTimeInterval(360) ?? .distantPast }
    public func isStale(at now: Date) -> Bool { now >= staleDate }

    public func replacingCover(_ cover: Data?) -> Self {
        var copy = self
        copy.cover = cover.flatMap { $0.count <= 1200 ? $0 : nil }
        return copy
    }

    /// Display-only arrangement: retain the six real history slots in the snapshot.
    public var waveformHeights: [Double?] {
        guard meterStyle == PrivacyMeterStyle.referenceFive.rawValue else { return heights }
        let recent = Array((recentHeights ?? heights.compactMap { $0 }).suffix(5))
        return Array(repeating: nil, count: 5 - recent.count) + recent.map(Optional.some) + [PrivacyMeterStyle.referenceHeight]
    }

    public func replacingMeterStyle(_ style: PrivacyMeterStyle) -> Self {
        var copy = self
        copy.meterStyle = style == .history ? nil : style.rawValue
        return copy
    }
}

public enum PrivacyGlucoseAlarm: String, CaseIterable, Sendable {
    case urgentLow, low, forecastedLow, high, carbsRequired

    public init?(identifier: String) {
        let parts = identifier.split(separator: ".")
        guard parts.count >= 2, parts[0] == "glucose", let value = Self(rawValue: String(parts[1])) else { return nil }
        self = value
    }

    public var color: PrivacyColor {
        switch self {
        case .urgentLow: return PrivacyColor.palette[0]
        case .low, .forecastedLow, .carbsRequired: return PrivacyColor.palette[1]
        case .high: return PrivacyColor.palette[5]
        }
    }
}

public enum PrivacyText {
    public static var attention: String { String(localized: "Attention", bundle: .module) }
}

import Foundation

public enum MedtrumBasalPulseError: LocalizedError {
    case alarmUnavailable
    case cannotRepresent
    public var errorDescription: String? {
        switch self {
        case .alarmUnavailable: return String(localized: "System alarm protection is unavailable for this temporary delivery.")
        case .cannotRepresent: return String(localized: "SMB plan cannot be represented within the saved basal limit")
        }
    }
}

/// Transport plan only. The native dosing algorithm supplies the insulin budget.
public struct MedtrumBasalPulsePlan: Codable, Equatable {
    public let requestedUnits: Double
    public let rate: Double
    public let minutes: Int
    public let companionRate: Double
    public let companionMinutes: Int
    public var extraUnits: Double { (rate - companionRate) * Double(minutes) / 60 }

    public static func make(units: Double, companionRate: Double, companionMinutes: Int,
                            supportedRates: [Double], maximumRate: Double) -> Self? {
        guard units.isFinite, units > 0, companionRate.isFinite, companionRate >= 0,
              (0 ... 120).contains(companionMinutes), maximumRate.isFinite,
              maximumRate > companionRate, maximumRate <= 30 else { return nil }
        let rates = supportedRates.filter { $0.isFinite && $0 >= 0 && $0 <= maximumRate }.sorted()
        guard !rates.isEmpty else { return nil }
        for minutes in MedtrumShortTempBasal.supportedMinutes {
            guard companionMinutes == 0 || minutes < companionMinutes else { continue }
            let required = companionRate + units * 60 / Double(minutes)
            guard required.isFinite, required <= maximumRate + 0.00000001 else { continue }
            // A rate-table entry may have a binary rounding tail. Never exceed the insulin budget.
            guard let rate = rates.last(where: {
                $0 <= required + 0.000000001 &&
                    ($0 - companionRate) * Double(minutes) / 60 <= units + 0.000000001
            }), rate > companionRate else { continue }
            return Self(requestedUnits: units, rate: rate, minutes: minutes,
                        companionRate: companionRate, companionMinutes: companionMinutes)
        }
        return nil
    }
}

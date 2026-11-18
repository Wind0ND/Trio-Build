import Foundation

enum AutosensError: LocalizedError, Equatable {
    case missingIsfProfile
    case missingCarbRatioInProfile
    case missingCurrentBasalInProfile
    case missingSensInProfile
    case missingMaxDailyBasalInProfile
    case isfLookupError

    var errorDescription: String? {
        switch self {
        case .missingIsfProfile:
            return String(localized: "No ISF set on the profile")
        case .missingCarbRatioInProfile:
            return String(localized: "Carb ratio is not set on the profile")
        case .missingCurrentBasalInProfile:
            return String(localized: "Current basal is not set on the profile")
        case .missingSensInProfile:
            return String(localized: "Sensitivity is not set on the profile")
        case .missingMaxDailyBasalInProfile:
            return String(localized: "Max Daily Basal is not set on the profile")
        case .isfLookupError:
            return String(localized: "Unable to lookup the ISF")
        }
    }
}

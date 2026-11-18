import Foundation

enum IobError: LocalizedError, Equatable {
    case tempBasalDurationMismatch
    case tempBasalMissingDuration(timestamp: Date)
    case tempBasalDurationMissingDuration(timestamp: Date)
    case pumpSuspendResumeMismatch
    case basalRateNotSet
    case rateNotSetOnTempBasal(timestamp: Date)
    case bilinearCurveNotSupported
    case diaNotSet

    var errorDescription: String? {
        switch self {
        case .tempBasalDurationMismatch:
            return String(localized: "Incomplete temp basal / duration pair")
        case let .tempBasalMissingDuration(timestamp):
            return String(localized: "Temp basal is missing duration @ \(String(describing: timestamp))")
        case let .tempBasalDurationMissingDuration(timestamp):
            return String(localized: "Temp basal duration @ \(String(describing: timestamp)) pump history entry without a duration set")
        case .pumpSuspendResumeMismatch:
            return String(localized: "Had two consecutive pump suspend or resume events")
        case .basalRateNotSet:
            return String(localized: "Unable to derive the current basal rate from the profile data")
        case let .rateNotSetOnTempBasal(timestamp):
            return String(localized: "Temp basal @ \(String(describing: timestamp)) without a rate set")
        case .bilinearCurveNotSupported:
            return String(localized: "Bilinear curve not supported in Trio")
        case .diaNotSet:
            return String(localized: "DIA not set on Profile")
        }
    }
}

import Foundation

enum ProfileError: LocalizedError, Equatable {
    case invalidDIA(value: Decimal)
    case invalidCurrentBasal(value: Decimal?)
    case invalidMaxDailyBasal(value: Decimal?)
    case invalidMaxBasal(value: Decimal?)
    case invalidISF(value: Decimal?)
    case invalidCarbRatio
    case invalidBgTargets
    case invalidCalendar

    var errorDescription: String? {
        switch self {
        case let .invalidDIA(value):
            return String(localized: "DIA of \(String(describing: value)) is not supported (must be > 1)")
        case let .invalidCurrentBasal(value):
            return String(localized: "Current basal of \(String(describing: value)) is not supported (must be > 0)")
        case let .invalidMaxDailyBasal(value):
            return String(localized: "Max daily basal of \(String(describing: value)) is not supported (must be > 0)")
        case let .invalidMaxBasal(value):
            return String(localized: "Max basal of \(String(describing: value)) is not supported (must be >= 0.1)")
        case let .invalidISF(value):
            return String(localized: "ISF of \(String(describing: value)) is not supported (must be >= 5)")
        case .invalidCarbRatio:
            return String(localized: "Profile wasn't given carb ratio data, cannot calculate carb_ratio")
        case .invalidBgTargets:
            return String(localized: "Profile wasn't given bg target data")
        case .invalidCalendar:
            return String(localized: "Unable to extract hours and minutes from the current calendar")
        }
    }
}

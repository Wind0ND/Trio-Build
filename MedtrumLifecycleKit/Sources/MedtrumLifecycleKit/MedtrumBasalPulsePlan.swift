import Foundation

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
        nil // Inert API seam: RED tests must prove absent transport mapping before implementation.
    }
}

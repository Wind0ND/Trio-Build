import Foundation

enum PumpEventAcceptance {
    /// Actual Medtrum records remain part of IOB even if the user later lowers the command ceiling.
    static func acceptsTemporaryBasal(rate: Double, configuredMaximum: Double, isMedtrum: Bool) -> Bool {
        if isMedtrum { return rate.isFinite && (0 ... 30).contains(rate) }
        return rate <= configuredMaximum
    }
}

import Foundation
import MedtrumLifecycleKit

public struct MedtrumAutomaticBolusContext: Equatable {
    public let sessionID: Data?
    public let sessionStartedAt: Date?
    public let allowsAutomaticBolus: Bool
    public let restrictionReason: String
}

extension MedtrumPumpState {
    func automaticBolusRestriction(at now: Date) -> MedtrumExtendedLifePolicy.Restriction {
        extendedLifePolicy.restriction(
            extended: expiryMode == .extended,
            activeSession: !patchSessionEnded && pumpState.isDelivering,
            sessionID: patchId, activatedAt: patchActivatedAt, now: now
        )
    }

    public func isExtendedBasalOnly(at now: Date = Date()) -> Bool {
        automaticBolusRestriction(at: now) == .extendedAgeLimit
    }
}

extension MedtrumPumpManager {
    public func automaticBolusContext(at now: Date = Date()) -> MedtrumAutomaticBolusContext {
        deliveryLock.withLock {
            let restriction = state.automaticBolusRestriction(at: now)
            return MedtrumAutomaticBolusContext(
                sessionID: state.patchSessionEnded ? nil : state.patchId,
                sessionStartedAt: state.patchSessionEnded ? nil : state.patchActivatedAt,
                allowsAutomaticBolus: restriction == .none,
                restrictionReason: restriction.rawValue
            )
        }
    }
}

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
            extended: expiryMode == .extended && model == "MD8301",
            activeSession: !patchSessionEnded && pumpState.isDelivering,
            sessionID: patchId, activatedAt: patchActivatedAt, now: now
        )
    }

    public func canShowExtendedBasalOnlyStatus(at now: Date = Date()) -> Bool {
        isExtendedBasalOnly(at: now) && basalState != .suspended && !basalDeliveryUncertain &&
            !awaitingBasalReply && reservoir >= 1 && (0 ... 720).contains(now.timeIntervalSince(lastSync))
    }

    public func isExtendedBasalOnly(at now: Date = Date()) -> Bool {
        automaticBolusRestriction(at: now) == .extendedAgeLimit
    }
}

extension MedtrumPumpManager {
    public func automaticBolusContext(at now: Date = Date()) -> MedtrumAutomaticBolusContext {
        deliveryLock.withLock {
            let previousPolicy = state.extendedLifePolicy
            let restriction = state.extendedLifePolicy.evaluate(
                extended: state.expiryMode == .extended && state.model == "MD8301",
                activeSession: !state.patchSessionEnded && state.pumpState.isDelivering,
                sessionID: state.patchId, activatedAt: state.patchActivatedAt, now: now
            )
            if previousPolicy != state.extendedLifePolicy {
                try? persistPendingDelivery?()
                notifyStateDidChange()
            }
            return MedtrumAutomaticBolusContext(
                sessionID: state.patchSessionEnded ? nil : state.patchId,
                sessionStartedAt: state.patchSessionEnded ? nil : state.patchActivatedAt,
                allowsAutomaticBolus: restriction == .none,
                restrictionReason: restriction.rawValue
            )
        }
    }
}

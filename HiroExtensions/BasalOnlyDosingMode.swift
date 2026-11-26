import LoopKit
import MedtrumKit

extension DosingMode {
    func effectiveForPump(_ pump: PumpManager?) -> Self {
        if usesBasalPulse, (pump as? MedtrumPumpManager)?.supportsAutomaticBasalPulse != true { return .basalOnly }
        let restricted = (pump as? MedtrumPumpManager)?.automaticBolusContext().restrictionReason == "basal_only"
        return effectiveForDevice(basalOnly: restricted)
    }
}

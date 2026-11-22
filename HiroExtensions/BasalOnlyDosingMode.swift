import LoopKit
import MedtrumKit

extension DosingMode {
    func effectiveForPump(_ pump: PumpManager?) -> Self {
        let restricted = (pump as? MedtrumPumpManager)?.automaticBolusContext().restrictionReason == "basal_only"
        return effectiveForDevice(basalOnly: restricted)
    }
}

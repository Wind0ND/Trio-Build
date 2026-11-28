import LoopKit
import MedtrumKit

extension DosingMode {
    func effectiveForPump(_ pump: PumpManager?) -> Self {
        if usesBasalPulse, (pump as? MedtrumPumpManager)?.supportsAutomaticBasalPulse != true { return .basalOnly }
        let medtrum = pump as? MedtrumPumpManager
        let restricted = medtrum?.automaticBolusContext().restrictionReason == "basal_only"
        return effectiveForDevice(basalOnly: restricted,
            pulseAvailable: medtrum?.isExtendedPulseWindow() == true && medtrum?.supportsAutomaticBasalPulse == true)
    }
}

import Foundation

/// How much of a determination Trio is allowed to enact on the pump.
enum AutomationLevel {
    /// Nothing reaches the pump. Trio forecasts and recommends only.
    case off
    /// Only a suspend when glucose is genuinely low. No other adjustment, in either direction.
    case hypoSuspendOnly
    /// Reductions only. Trio may lower or zero basal but never deliver above the scheduled rate.
    case reductionsOnly
    /// Basal reductions and corrections; automatic SMB still follows the mode and device capability.
    case full
}

/// How much of Trio's dosing decision is enacted, and under which constraints.
enum DosingMode: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }
    case closed
    case basalOnly
    case basalPulse
    case open
    case lowGlucoseSuspend
    case basalTesting

    /// Both closed-loop modes allow basal corrections; the constrained modes
    /// can take insulin away but never add it, because Max IOB is clamped to 0.
    var automation: AutomationLevel {
        switch self {
        case .closed, .basalOnly, .basalPulse:
            return .full
        case .open:
            return .off
        case .lowGlucoseSuspend:
            return .reductionsOnly
        case .basalTesting:
            return .hypoSuspendOnly
        }
    }

    var allowsAutomaticSMB: Bool { self != .basalOnly && self != .basalPulse }
    var usesBasalPulse: Bool { self == .basalPulse }
    func allowsSMBDecision(automaticBolusAllowed: Bool) -> Bool {
        usesBasalPulse || (automaticBolusAllowed && allowsAutomaticSMB)
    }

    /// A device restriction changes the effective mode, not the user's stored selection.
    func effectiveForDevice(basalOnly: Bool, pulseAvailable: Bool = false) -> Self {
        self == .closed && basalOnly ? (pulseAvailable ? .basalPulse : .basalOnly) : self
    }

    /// Modes offered in Settings.
    static var userSelectable: [DosingMode] { allCases }

    var displayName: String {
        switch self {
        case .closed:
            return String(localized: "Closed Loop", comment: "Dosing mode")
        case .basalOnly:
            return String(localized: "Basal-only Closed Loop")
        case .basalPulse:
            return String(localized: "Basal Pulse Closed Loop")
        case .open:
            return String(localized: "Open Loop", comment: "Dosing mode")
        case .lowGlucoseSuspend:
            return String(localized: "Low Glucose Suspend", comment: "Dosing mode")
        case .basalTesting:
            return String(localized: "Basal Testing", comment: "Dosing mode")
        }
    }

    var miniHint: String {
        switch self {
        case .closed:
            return String(localized: "Trio adjusts your insulin automatically.")
        case .basalOnly:
            return String(localized: "Automatically adjusts basal insulin without SMB.")
        case .basalPulse:
            return String(localized: "Uses native SMB decisions through short temporary basal delivery.")
        case .open:
            return String(localized: "Trio only shows what it would do. It never changes your insulin.")
        case .lowGlucoseSuspend:
            return String(localized: "Trio may only lower basal insulin. It will not correct highs.")
        case .basalTesting:
            return String(localized: "Trio steps in only if your glucose goes low.")
        }
    }

    /// Symbol shown beside the name in the hint sheet.
    var icon: String {
        switch self {
        case .closed, .basalOnly, .basalPulse:
            return "circle"
        case .open:
            return "circle.dashed"
        case .lowGlucoseSuspend:
            return "hand.raised.fill"
        case .basalTesting:
            return "waveform"
        }
    }

    var description: String {
        switch self {
        case .closed:
            return String(
                localized: "Trio checks your glucose every five minutes and changes your insulin for you. You need a working CGM and a connected pump."
            )
        case .basalOnly:
            return String(localized: "Trio automatically raises or lowers basal insulin using its existing algorithm. Automatic SMB is off. Your saved SMB preferences and safety limits stay unchanged. Manual boluses remain available.")
        case .basalPulse:
            return String(localized: "Uses the existing SMB algorithm for all eligible automatic corrections, delivered only through temporary basal commands. With native short timing enabled, the pump receives the requested minutes directly. Otherwise a system alarm must be armed before starting and the phone cancels the longer temporary basal. Existing safety limits remain in effect.")
        case .open:
            return String(
                localized: "Trio still shows what it would do, but it never changes your insulin. Your pump keeps running the basal rates you set, and every dose is your choice. Trio is running in manual mode. It will not stop a low or fix a high for you."
            )
        case .lowGlucoseSuspend:
            return String(
                localized: "Trio may lower or stop your basal insulin when it forecasts you are heading low. It will never give extra insulin to bring a high down.\nTrio does not wait for one set glucose number. It watches your forecast and lowers basal early. While this mode is on, Trio acts as if your Max IOB is 0. Your saved setting does not change.\nIf IOB is negative from LGS lowering your basal, it may give additional insulin until IOB reaches 0."
            )
        case .basalTesting:
            return String(
                localized: "Use this to check whether your basal rates hold you steady. Trio makes no changes unless your glucose goes low. Then it stops your basal until you come back up.\nTrio also stops adjusting for sensitivity, so you see your own settings at work. Turning this on cancels any temp basal Trio set. Use it for short, planned times."
            )
        }
    }
}

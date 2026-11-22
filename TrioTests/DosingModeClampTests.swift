import Foundation
import Testing
@testable import Trio

@Suite("Dosing Mode Clamps") struct DosingModeClampTests {
    private func userPreferences() -> Preferences {
        var preferences = Preferences()
        preferences.maxIOB = 7
        preferences.autosensMin = 0.7
        preferences.autosensMax = 1.2
        preferences.useNewFormula = true
        preferences.sigmoid = true
        preferences.threshold_setting = 65
        return preferences
    }

    @Test("Closed and open loop see the user's own preferences") func unclampedModes() {
        let preferences = userPreferences()
        for mode in [DosingMode.closed, .open] {
            #expect(preferences.clamped(for: mode) == preferences)
        }
    }

    @Test("Low glucose suspend only zeroes Max IOB") func lowGlucoseSuspendClamp() {
        let preferences = userPreferences()
        let clamped = preferences.clamped(for: .lowGlucoseSuspend)

        #expect(clamped.maxIOB == 0)
        // Sensitivity adaptation is untouched: this mode still adapts, it just cannot add insulin.
        #expect(clamped.autosensMin == preferences.autosensMin)
        #expect(clamped.autosensMax == preferences.autosensMax)
        #expect(clamped.useNewFormula == preferences.useNewFormula)
        #expect(clamped.threshold_setting == preferences.threshold_setting)
    }

    @Test("Basal testing also pins sensitivity and raises the threshold") func basalTestingClamp() {
        let clamped = userPreferences().clamped(for: .basalTesting)

        #expect(clamped.maxIOB == 0)
        #expect(clamped.autosensMin == 1)
        #expect(clamped.autosensMax == 1)
        #expect(clamped.useNewFormula == false)
        #expect(clamped.sigmoid == false)
        #expect(clamped.threshold_setting == Preferences.basalTestingThreshold)
    }

    @Test("Basal testing never lowers a threshold the user set higher") func basalTestingKeepsHigherThreshold() {
        var preferences = userPreferences()
        preferences.threshold_setting = 90
        #expect(preferences.clamped(for: .basalTesting).threshold_setting == 90)
    }

    @Test("Clamping never mutates the stored preferences") func clampIsNonDestructive() {
        let preferences = userPreferences()
        for mode in DosingMode.allCases {
            _ = preferences.clamped(for: mode)
        }
        #expect(preferences.maxIOB == 7)
        #expect(preferences.autosensMax == 1.2)
        #expect(preferences.useNewFormula)
    }

    @Test("suspendOnly stays out of profile.json so the JS parity goldens hold") func suspendOnlyIsNotSerialised() throws {
        var profile = Profile()
        profile.suspendOnly = true

        let encoded = try JSONEncoder().encode(profile)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("suspendOnly"))

        // It is derived from the dosing mode at determination time, so it defaults off on decode.
        let decoded = try JSONDecoder().decode(Profile.self, from: encoded)
        #expect(decoded.suspendOnly == false)
    }
}

@Suite("Automatic delivery context") struct AutomaticDeliveryContextTests {
    @Test("Only the calculating mode, glucose source revision and pump may send the next command")
    func rejectsChangedInputs() {
        let pump = NSObject()
        let replacement = NSObject()
        let revision = UUID()
        let now = Date()
        func context(_ mode: DosingMode = .closed, _ epoch: UUID? = nil, _ device: NSObject? = nil,
                     simulated: Bool = false, mock: Bool = false) -> AutomaticDeliveryContext {
            AutomaticDeliveryContext(mode: mode, modeRevision: revision, sourceRevision: epoch ?? revision, pumpID: ObjectIdentifier(device ?? pump),
                                     simulatorSource: simulated, mockPump: mock)
        }
        let start = context()
        #expect(start.permitsDelivery(current: start, deliverAt: now, now: now))
        for changed in [context(.basalTesting), context(.open), context(.closed, UUID()), context(.closed, revision, replacement)] {
            #expect(!start.permitsDelivery(current: changed, deliverAt: now, now: now))
        }
        #expect(!start.permitsDelivery(current: start, deliverAt: now.addingTimeInterval(-1801), now: now))
        let incompatible = context(simulated: true)
        #expect(!incompatible.permitsDelivery(current: incompatible, deliverAt: now, now: now))
        let simulated = context(simulated: true, mock: true)
        #expect(simulated.permitsDelivery(current: simulated, deliverAt: now, now: now))
    }
}

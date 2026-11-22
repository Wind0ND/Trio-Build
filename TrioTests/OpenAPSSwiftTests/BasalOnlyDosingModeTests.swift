import Foundation
import Testing
@testable import Trio

@Suite("Basal-only closed-loop mode") struct BasalOnlyDosingModeTests {
    @Test("Basal-only mode is an automated mode and preserves basal, IOB and sensitivity limits")
    func manualModeIsAvailable() throws {
        let mode = try #require(DosingMode(rawValue: "basalOnly"))
        #expect(mode.automation == .full)
        #expect(!mode.allowsAutomaticSMB)
        #expect(DosingMode.closed.allowsAutomaticSMB)
        #expect(DosingMode.closed.effectiveForDevice(basalOnly: true) == mode)
        #expect(DosingMode.closed.effectiveForDevice(basalOnly: false) == .closed)
        #expect(mode.effectiveForDevice(basalOnly: false) == mode)
        #expect(DosingMode.open.effectiveForDevice(basalOnly: true) == .open)
        var preferences = Preferences()
        preferences.maxIOB = 6
        preferences.autosensMin = 0.7
        preferences.autosensMax = 1.2
        #expect(preferences.clamped(for: mode) == preferences)
        #expect(DosingMode.userSelectable.contains(mode))
        #expect(try JSONDecoder().decode(DosingMode.self, from: JSONEncoder().encode(mode)) == mode)
    }
}

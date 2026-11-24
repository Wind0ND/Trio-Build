import Testing
@testable import Trio

@Suite("Physically reported basal event acceptance")
struct PumpEventAcceptanceTests {
    @Test func actualMedtrumDeliverySurvivesLaterLowerCommandLimit() {
        #expect(PumpEventAcceptance.acceptsTemporaryBasal(rate: 6, configuredMaximum: 2, isMedtrum: true))
        #expect(PumpEventAcceptance.acceptsTemporaryBasal(rate: 6, configuredMaximum: 6, isMedtrum: true))
        #expect(PumpEventAcceptance.acceptsTemporaryBasal(rate: 6, configuredMaximum: 10, isMedtrum: true))
        #expect(!PumpEventAcceptance.acceptsTemporaryBasal(rate: .nan, configuredMaximum: 10, isMedtrum: true))
        #expect(!PumpEventAcceptance.acceptsTemporaryBasal(rate: 40, configuredMaximum: 10, isMedtrum: true))
    }
    @Test func existingCeilingFilterForOtherDriversRemains() {
        #expect(!PumpEventAcceptance.acceptsTemporaryBasal(rate: 6, configuredMaximum: 2, isMedtrum: false))
        #expect(PumpEventAcceptance.acceptsTemporaryBasal(rate: 2, configuredMaximum: 2, isMedtrum: false))
    }
}

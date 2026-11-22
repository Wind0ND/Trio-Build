import LoopKitUI
@testable import Trio

struct MockTDDStorage: TDDStorage {
    func calculateTDD(
        pumpManager _: any LoopKitUI.PumpManagerUI,
        pumpHistory _: [Trio.PumpHistoryEvent],
        basalProfile _: [Trio.BasalProfileEntry]
    ) async throws -> Trio.TDDResult {
        TDDResult(total: 0, bolus: 0, tempBasal: 0, scheduledBasal: 0, weightedAverage: 0, hoursOfData: 0)
    }

    func storeTDD(_: Trio.TDDResult, simulated _: Bool) async { /* skip */ }
    func hasSufficientTDD(simulated _: Bool) async throws -> Bool { true }
}

import HealthKit
import Foundation
import LoopKit
import Testing

@testable import Trio

/// Tests for `CarbsEntry.convertSyncCarb()`, the mapping used for Tidepool uploads.
@Suite("CarbsEntry LoopKit Conversion Tests") struct CarbsEntryLoopKitTests {
    private func entry(id: String?) -> CarbsEntry {
        CarbsEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            actualDate: nil,
            carbs: 20,
            fat: nil,
            protein: nil,
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: nil
        )
    }

    @Test("A partially authorized meal exports allowed quantities and keeps remaining nutrients pending")
    func mealAuthorization() throws {
        let meal = CarbsEntry(id: "test-meal", createdAt: Date(), actualDate: nil, carbs: 15,
                              fat: 8, protein: 0, note: nil, enteredBy: nil, isFPU: false, fpuID: nil)
        let fat = try #require(AppleHealthConfig.healthFatObject)
        let partial = BaseHealthKitManager.nutritionExport([meal], authorized: { $0 == fat })
        #expect(partial.samples.map(\.quantityType) == [fat])
        #expect(partial.completed.isEmpty)
        let full = BaseHealthKitManager.nutritionExport([meal], authorized: { _ in true })
        #expect(full.samples.count == 2)
        #expect(full.completed.compactMap(\.id) == ["test-meal"])
    }

    @Test("An entry without id converts without a uuid or sync identifier") func testNilID() {
        let carb = entry(id: nil).convertSyncCarb()

        #expect(carb.uuid == nil)
        #expect(carb.syncIdentifier == nil)
    }

    @Test("A UUID id maps to uuid and sync identifier") func testUUIDID() {
        let id = "3D6BB81B-A387-4042-B0EC-BD38EF1A93C3"
        let carb = entry(id: id).convertSyncCarb()

        #expect(carb.uuid?.uuidString == id)
        #expect(carb.syncIdentifier == id)
    }
}

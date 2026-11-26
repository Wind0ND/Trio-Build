@testable import MedtrumKit
import LoopKit
import XCTest

final class UserBasalRecoveryTests: XCTestCase {
    func fixture() -> (MedtrumPumpManager, MedtrumBasalSyncContext, SynchronizePacketResponse) {
        let state = MedtrumPumpState(nil)
        state.patchId = UInt64(865).toData(length: 4)
        state.pumpSN = Data([0x39,0xb3,0x69,0x26])
        state.patchActivatedAt = Date().addingTimeInterval(-3600)
        state.patchSessionEnded = false; state.pumpState = .active; state.basalState = .active
        state.pendingTempBasal = UnfinalizedDose(decisionId: nil, tempRate: 1.1, duration: 1800, insulinType: nil,
            automatic: true, startDate: Date().addingTimeInterval(-1800))
        state.basalDeliveryUncertain = true
        let manager = MedtrumPumpManager(state: state, bluetooth: nil)
        let query = manager.captureBasalSyncContext()
        manager.userBasalRecoveryOwner = query.generation; manager.basalRecoveryInProgress = true
        var response = SynchronizePacketResponse(state: .active, activeAlarms: [])
        response.startTime = state.patchActivatedAt
        response.storage = StorageData(sequence: 909, patchId: 865)
        response.basal = BasalData(type: .STANDARD, sequence: 909, patchId: 865,
            startTime: Date().addingTimeInterval(-60), rate: 1, delivery: 0)
        return (manager, query, response)
    }
    func testExplicitChoicePersistsOriginalRequestWithoutClaimingVerifiedHistory() throws {
        let (manager, query, response) = fixture()
        var disk: MedtrumPumpState?
        manager.persistBasalRecovery = { transaction in
            try transaction { candidate in
                XCTAssertTrue(manager.state.basalDeliveryUncertain)
                disk = MedtrumPumpState(rawValue: candidate)
            }
        }
        try manager.commitUserBasalRecovery(query: query, status: response, observedAt: Date())
        XCTAssertFalse(manager.state.basalDeliveryUncertain)
        XCTAssertNil(manager.state.pendingTempBasal)
        let audit = try XCTUnwrap(disk?.userBasalRecoveryAudit.last)
        XCTAssertEqual(audit["historyVerified"] as? Bool, false)
        XCTAssertNotNil(audit["pending"])
        XCTAssertEqual(audit["action"] as? String, "user_resumed_current_loop")
        XCTAssertTrue(manager.hasUserAcknowledgedBasalHistory)
    }
    func testDiskFailureKeepsProtectionAndOriginalRequest() {
        let (manager, query, response) = fixture()
        manager.persistBasalRecovery = { transaction in try transaction { _ in throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try manager.commitUserBasalRecovery(query: query, status: response, observedAt: Date()))
        XCTAssertTrue(manager.state.basalDeliveryUncertain)
        XCTAssertNotNil(manager.state.pendingTempBasal)
    }
    func testIndependentUncertaintyAndChangedSessionRejectOverride() {
        for changedSession in [false, true] {
            let (manager, query, response) = fixture()
            manager.persistBasalRecovery = { transaction in try transaction { _ in XCTFail("Must not save") } }
            if changedSession { manager.state.patchId = UInt64(866).toData(length: 4) }
            else { manager.state.bolusDeliveryUncertain = true }
            XCTAssertThrowsError(try manager.commitUserBasalRecovery(query: query, status: response, observedAt: Date()))
            XCTAssertTrue(manager.state.basalDeliveryUncertain)
        }
    }
    func testChoiceTokenChangesWithIncidentAndKeepingProtectionDoesNotConsumeIt() {
        let (manager, _, _) = fixture()
        let token = manager.basalRecoveryDecisionToken
        XCTAssertNotNil(token)
        XCTAssertEqual(manager.basalRecoveryDecisionToken, token)
        manager.state.pendingTempBasal = UnfinalizedDose(decisionId: nil, tempRate: 2, duration: 1800, insulinType: nil, automatic: true)
        XCTAssertNotEqual(manager.basalRecoveryDecisionToken, token)
    }

    func testUnconfirmedOrStaleCurrentStatusCannotClearProtection() {
        for stale in [false, true] {
            let (manager, query, response) = fixture()
            var status = response
            if !stale {
                status.basal = BasalData(type: .ABSOLUTE_TEMP, sequence: 909, patchId: 865,
                    startTime: Date().addingTimeInterval(-60), rate: 1, delivery: 0)
            }
            manager.persistBasalRecovery = { transaction in try transaction { _ in XCTFail("Must not save") } }
            let observedAt = Date().addingTimeInterval(stale ? -300 : 0)
            XCTAssertThrowsError(try manager.commitUserBasalRecovery(query: query, status: status, observedAt: observedAt))
            XCTAssertTrue(manager.state.basalDeliveryUncertain)
        }
    }

    func testHistoricalMappingRequiresVerifiedPreRequestSampleAndSurvivesRestart() throws {
        let (manager, _, response) = fixture()
        let request = try XCTUnwrap(manager.state.pendingTempBasal)
        let sample = request.startDate.addingTimeInterval(-1)
        manager.verifiedBasalBaseline = MedtrumBasalRecoveryBaseline(segment: try XCTUnwrap(response.basal),
            sessionID: manager.state.patchId, sessionStartedAt: try XCTUnwrap(manager.state.patchActivatedAt), observedAt: sample)
        // Default/restored pumpTime fields cannot establish historical clock provenance.
        XCTAssertNil(try XCTUnwrap(manager.captureBasalRecoveryCheckpoint(for: request)).clockMapping)
        manager.verifiedClockMapping = MedtrumFrozenClockMapping(sessionID: manager.state.patchId,
            activation: try XCTUnwrap(manager.state.patchActivatedAt), sampledAt: sample, offset: -3)
        let checkpoint = try XCTUnwrap(manager.captureBasalRecoveryCheckpoint(for: request))
        let restored = try JSONDecoder().decode(MedtrumBasalRecoveryCheckpoint.self,
            from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(restored.clockMapping?.offset, -3)
        XCTAssertEqual(restored.clockMapping?.sampledAt, sample)
        manager.verifiedClockMapping = MedtrumFrozenClockMapping(sessionID: manager.state.patchId,
            activation: try XCTUnwrap(manager.state.patchActivatedAt), sampledAt: request.startDate.addingTimeInterval(1), offset: 0)
        XCTAssertNil(try XCTUnwrap(manager.captureBasalRecoveryCheckpoint(for: request)).clockMapping)
    }
}

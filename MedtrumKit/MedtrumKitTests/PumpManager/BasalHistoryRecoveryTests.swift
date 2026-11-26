@testable import MedtrumKit
import LoopKit
import XCTest

final class BasalHistoryRecoveryTests: XCTestCase {
    let serial: UInt64 = 0x39b36926
    let session = Date(timeIntervalSince1970: 1_700_000_000)
    var original: Date { session.addingTimeInterval(3600) }
    func basal(_ index: Int, _ type: BasalType, _ start: Date, _ rate: Double) -> BasalData {
        BasalData(type: type, sequence: Double(index), patchId: 865, startTime: start, rate: rate, delivery: 0)
    }
    func record(_ index: Int, _ type: BasalType, _ start: Date, _ end: Date, _ rate: Double) -> MedtrumBasalHistoryRecord {
        MedtrumBasalHistoryRecord(serial: serial, patchID: 865, sequence: index, type: type,
            start: start, end: end, rate: rate, delivered: rate * end.timeIntervalSince(start) / 3600,
            endReason: 0)
    }
    var request: UnfinalizedDose {
        UnfinalizedDose(decisionId: UUID(), tempRate: 1.1, duration: 1800, insulinType: nil,
            automatic: true, startDate: original)
    }
    var anchor: BasalData { basal(906, .ABSOLUTE_TEMP, original.addingTimeInterval(-300), 1.9) }
    var tip: BasalData { basal(909, .STANDARD, original.addingTimeInterval(9000), 1) }
    var incident: [MedtrumBasalHistoryRecord] {
        [record(906, .ABSOLUTE_TEMP, anchor.startTime, original, 1.9),
         record(907, .STANDARD, original, original.addingTimeInterval(3600), 0.8),
         record(908, .STANDARD, original.addingTimeInterval(3600), tip.startTime, 0.6)]
    }
    func resolve(_ records: [MedtrumBasalHistoryRecord], anchor: BasalData? = nil,
                 tip: BasalData? = nil, serial: UInt64? = nil) -> MedtrumBasalHistoryResolution? {
        MedtrumBasalHistoryResolution.reconcile(request: request, anchor: anchor ?? self.anchor,
            records: records, current: tip ?? self.tip, serial: serial ?? self.serial,
            patchID: 865, activation: session, clockOffset: 0)
    }
    func testIncidentAcrossSeveralScheduledSegmentsProvesNoNewTemp() throws {
        XCTAssertNil(try XCTUnwrap(resolve(incident)).executed)
    }
    func testCheckpointStandardAnchorAlsoSpansScheduleChanges() throws {
        XCTAssertNil(try XCTUnwrap(resolve(Array(incident.dropFirst()),
            anchor: basal(907, .STANDARD, original, 0.8))).executed)
    }
    func testMissingReorderedForeignOrChangedAnchorCannotUnlock() {
        XCTAssertNil(resolve([incident[0], incident[2]]))
        XCTAssertNil(resolve(Array(incident.reversed())))
        XCTAssertNil(resolve(incident, serial: serial + 1))
        XCTAssertNil(resolve(incident, anchor: basal(906, .ABSOLUTE_TEMP, anchor.startTime, 2)))
    }
    func testGapOrClockJumpCannotUnlock() {
        let gap = record(907, .STANDARD, original.addingTimeInterval(1), original.addingTimeInterval(3600), 0.8)
        XCTAssertNil(resolve([incident[0], gap, incident[2]]))
    }
    func testMatchingExecutedTempIsRecoveredFromActualInterval() throws {
        let start = original.addingTimeInterval(1)
        let end = start.addingTimeInterval(1800)
        let records = [incident[0], record(907, .STANDARD, original, start, 0.8),
            record(908, .ABSOLUTE_TEMP, start, end, 1.1)]
        let result = try XCTUnwrap(resolve(records, tip: basal(909, .STANDARD, end, 0.8)))
        XCTAssertEqual(result.executed?.sequence, 908)
        XCTAssertEqual(result.executed?.end, end)
    }
    func testDifferentOrAdditionalTempCannotBeAssumedToBeOurRequest() {
        let start = original.addingTimeInterval(1), end = original.addingTimeInterval(1801)
        let records = [incident[0], record(907, .STANDARD, original, start, 0.8),
            record(908, .ABSOLUTE_TEMP, start, end, 3)]
        XCTAssertNil(resolve(records, tip: basal(909, .STANDARD, end, 0.8)))
    }
    func testCurrentTempOrOtherPatchCannotProveNoExecution() {
        XCTAssertNil(resolve(incident, tip: basal(909, .ABSOLUTE_TEMP, tip.startTime, 1.1)))
        let other = BasalData(type: .STANDARD, sequence: 909, patchId: 866, startTime: tip.startTime, rate: 1, delivery: 0)
        XCTAssertNil(resolve(incident, tip: other))
    }
}

final class GetBasalRecordPacketTests: XCTestCase {
    // Captured AndroidAPS primary reference GetRecordPacketTest basal fixture, already reassembled.
    let captured = Data([35,99,7,1,0,0,170,28,2,255,38,105,179,57,56,0,30,0,
        171,171,62,18,222,172,62,18,6,0,69,0,6,0,69,0,131])
    func packet(_ bytes: Data? = nil, index: Int = 30, patch: Int = 56) -> GetBasalRecordPacket {
        let result = GetBasalRecordPacket(index: index, patchID: patch)
        result.totalData = bytes ?? captured
        return result
    }
    func testNativeReadRequestUsesIndexAndPatchLittleEndian() {
        XCTAssertEqual(packet().getRequestBytes(), Data([30,0,56,0]))
        XCTAssertEqual(packet().commandType, 99)
    }
    func testCapturedRecordParsesActualFields() throws {
        let r = try XCTUnwrap(packet().parseResponse())
        XCTAssertEqual(r.serial, 0x39b36926)
        XCTAssertEqual(r.patchID, 56)
        XCTAssertEqual(r.sequence, 30)
        XCTAssertEqual(r.type, .ABSOLUTE_TEMP)
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 1694631467))
        XCTAssertEqual(r.end, Date(timeIntervalSince1970: 1694631774))
        XCTAssertEqual(r.rate, 3.45, accuracy: 0.00001)
        XCTAssertEqual(r.delivered, 0.3, accuracy: 0.00001)
    }
    func testTruncatedBadHeaderWrongIndexAndPatchFailClosed() {
        XCTAssertNil(packet(Data(captured.prefix(18))).parseResponse())
        var bytes = captured; bytes[6] = 0
        XCTAssertNil(packet(bytes).parseResponse())
        XCTAssertNil(packet(index: 31).parseResponse())
        XCTAssertNil(packet(patch: 57).parseResponse())
        bytes = captured; bytes[8] = 1
        XCTAssertNil(packet(bytes).parseResponse())
    }
}

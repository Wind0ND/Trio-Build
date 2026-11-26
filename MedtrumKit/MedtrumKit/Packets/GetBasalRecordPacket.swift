import Foundation

/// Reassembled, ended basal record. Raw native times are retained for continuity proofs.
struct MedtrumBasalHistoryRecord {
    let serial: UInt64
    let patchID: Int
    let sequence: Int
    let type: BasalType
    let start: Date
    let end: Date
    let rate: Double
    let delivered: Double
    let endReason: UInt8
}

/// Read-only GET_RECORD. Unsupported record kinds are never silently skipped.
final class GetBasalRecordPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = MedtrumBasalHistoryRecord?
    let commandType: UInt8 = CommandType.GET_RECORD
    let mimimumDataSize = 18
    let index: Int
    let patchID: Int
    init(index: Int, patchID: Int) { self.index = index; self.patchID = patchID }
    func getRequestBytes() -> Data {
        UInt64(index).toData(length: 2) + UInt64(patchID).toData(length: 2)
    }
    func parseResponse() -> MedtrumBasalHistoryRecord? {
        guard !failed, responseCode == 0, totalData.count >= 35,
              Int(totalData[0]) == totalData.count, totalData[6] == 0xaa,
              [UInt8(2), UInt8(66)].contains(totalData[8]),
              (1...65535).contains(index), (1...65535).contains(patchID),
              Int(totalData.subdata(in: 14..<16).toUInt64()) == patchID,
              Int(totalData.subdata(in: 16..<18).toUInt64()) == index,
              let type = BasalType(rawValue: totalData[26]),
              type == .STANDARD || type == .ABSOLUTE_TEMP else { return nil }
        let start = Date.fromMedtrumSeconds(totalData.subdata(in: 18..<22).toUInt64())
        let end = Date.fromMedtrumSeconds(totalData.subdata(in: 22..<26).toUInt64())
        guard end >= start else { return nil }
        let rate = totalData.subdata(in: 28..<30).toDouble() * 0.05
        let delivered = totalData.subdata(in: 30..<32).toDouble() * 0.05
        guard (0...30).contains(rate), delivered <= rate * end.timeIntervalSince(start) / 3600 + 0.050001 else { return nil }
        return MedtrumBasalHistoryRecord(serial: totalData.subdata(in: 10..<14).toUInt64(),
            patchID: patchID, sequence: index, type: type, start: start, end: end,
            rate: rate, delivered: delivered, endReason: totalData[27])
    }
}

import Foundation
import XCTest

@testable import AiDEXKit

final class AiDEXFrameDecoderTests: XCTestCase {
    // Synthetic payload: active minute 1234, status 0, current word 0x8078
    // (bit 15 set, 120 mg/dL). The checksum 0xD1FE2B9B was calculated
    // independently from the published algorithm, not by AiDEXFrameDecoder.
    private let validFrame: [UInt8] = [
        0x59, 0x00,
        0xD2, 0x04, 0x00, 0x11, 0x22, 0x78, 0x80,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x9B, 0x2B, 0xFE, 0xD1
    ]

    private let nextFrame: [UInt8] = [
        0x59, 0x00,
        0xD3, 0x04, 0x00, 0x11, 0x22, 0x79, 0x80,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0xB4, 0xA7, 0xD0, 0xF2
    ]

    private func decode(_ bytes: [UInt8]) -> AiDEXFrameDecodeResult {
        AiDEXFrameDecoder.decode(manufacturerData: Data(bytes))
    }

    private func assertRejected(
        _ bytes: [UInt8],
        _ expected: AiDEXFrameRejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch decode(bytes) {
        case let .rejected(rejection):
            XCTAssertEqual(rejection, expected, file: file, line: line)
        case let .success(frame):
            XCTFail("Expected rejection, decoded \(frame)", file: file, line: line)
        }
    }

    func testDecodesKnownFrame() throws {
        guard case let .success(frame) = decode(validFrame) else {
            return XCTFail("Expected a valid frame")
        }
        XCTAssertEqual(frame.activeMinutes, 1234)
        XCTAssertEqual(frame.status, 0)
        XCTAssertEqual(frame.currentWord, 0x8078)
        XCTAssertEqual(frame.glucoseMgdL, 120)
    }

    func testDecodesNextKnownFrame() throws {
        guard case let .success(frame) = decode(nextFrame) else {
            return XCTFail("Expected a valid frame")
        }
        XCTAssertEqual(frame.activeMinutes, 1235)
        XCTAssertEqual(frame.currentWord, 0x8079)
        XCTAssertEqual(frame.glucoseMgdL, 121)
    }

    func testRejectsScanResponseAndWrongSizes() {
        // CoreBluetooth prefixes the five-byte scan response with the company ID.
        assertRejected([0x59, 0x00, 0x03, 0x05, 0x06, 0x49, 0x37], .scanResponse)
        assertRejected([0x58, 0x00, 0x03, 0x05, 0x06, 0x49, 0x37], .unexpectedCompanyID)
        assertRejected([0x59, 0x00, 0x01, 0x02, 0x03], .wrongLength(5))
        assertRejected(Array(validFrame.prefix(21)), .wrongLength(21))
        assertRejected(validFrame + [0x00], .wrongLength(23))
    }

    func testRejectsIncorrectCompanyID() {
        var bytes = validFrame
        bytes[0] = 0x58
        assertRejected(bytes, .unexpectedCompanyID)
    }

    func testRejectsCorruptChecksum() {
        var bytes = validFrame
        bytes[21] ^= 0x01
        assertRejected(bytes, .checksumMismatch)
    }

    func testRejectsNonZeroStatus() {
        // Same fields as the known frame, status 1, independently calculated CRC.
        assertRejected([
            0x59, 0x00,
            0xD2, 0x04, 0x01, 0x11, 0x22, 0x78, 0x80,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x6A, 0x78, 0xA4, 0x8C
        ], .statusNotReady(1))
    }

    func testRejectsExpiredAndSentinelFrames() {
        assertRejected([
            0x59, 0x00,
            0x60, 0x54, 0x00, 0x11, 0x22, 0x78, 0x80,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x43, 0x7D, 0x3D, 0xC8
        ], .expired(21_600))

        assertRejected([
            0x59, 0x00,
            0xD2, 0x04, 0x00, 0x11, 0x22, 0xFF, 0xFF,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x76, 0x6B, 0x74, 0x7A
        ], .sentinelWord)
    }

    func testRejectsMissingCurrentFlag() {
        assertRejected([
            0x59, 0x00,
            0xD2, 0x04, 0x00, 0x11, 0x22, 0x78, 0x00,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x95, 0xB9, 0x07, 0xEF
        ], .currentFlagMissing)
    }

    func testRejectsOutOfRangeGlucose() {
        // 17 mg/dL, independently calculated CRC.
        assertRejected([
            0x59, 0x00,
            0xD2, 0x04, 0x00, 0x11, 0x22, 0x11, 0x80,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x35, 0xFB, 0xF6, 0x18
        ], .glucoseOutOfRange(17))

        // 801 mg/dL, independently calculated CRC.
        assertRejected([
            0x59, 0x00,
            0xD2, 0x04, 0x00, 0x11, 0x22, 0x21, 0x83,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x1F, 0x6C, 0xEB, 0xD0
        ], .glucoseOutOfRange(801))
    }

    func testMapsEveryRejectionToTheFiniteProbeIssue() {
        XCTAssertNil(AiDEXFrameRejection.scanResponse.measurementIssue)
        XCTAssertEqual(AiDEXFrameRejection.wrongLength(5).measurementIssue, .unsupportedManufacturerFrame)
        XCTAssertEqual(
            AiDEXFrameRejection.wrongLength(21).measurementIssue,
            .unsupportedManufacturerFrame
        )
        XCTAssertEqual(
            AiDEXFrameRejection.unexpectedCompanyID.measurementIssue,
            .unsupportedManufacturerFrame
        )
        XCTAssertEqual(AiDEXFrameRejection.checksumMismatch.measurementIssue, .checksumMismatch)

        let unavailable: [AiDEXFrameRejection] = [
            .statusNotReady(1),
            .expired(21_600),
            .sentinelWord,
            .currentFlagMissing,
            .glucoseOutOfRange(17)
        ]
        for rejection in unavailable {
            XCTAssertEqual(rejection.measurementIssue, .readingUnavailable)
        }
    }

    func testAcceptsAgeAndGlucoseBoundaries() throws {
        // 21599 active minutes, 120 mg/dL.
        guard case let .success(frame) = decode([
            0x59, 0x00,
            0x5F, 0x54, 0x00, 0x11, 0x22, 0x78, 0x80,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x62, 0xB6, 0x28, 0x84
        ]) else {
            return XCTFail("Expected the last valid minute")
        }
        XCTAssertEqual(frame.activeMinutes, 21_599)

        // 18 mg/dL.
        guard case let .success(low) = decode([
            0x59, 0x00,
            0x2C, 0x01, 0x00, 0x11, 0x22, 0x12, 0x80,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0xAC, 0x42, 0x64, 0xB2
        ]) else {
            return XCTFail("Expected the lowest valid glucose")
        }
        XCTAssertEqual(low.glucoseMgdL, 18)

        // 800 mg/dL.
        guard case let .success(high) = decode([
            0x59, 0x00,
            0x2C, 0x01, 0x00, 0x11, 0x22, 0x20, 0x83,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0xBA, 0x31, 0x2C, 0x2F
        ]) else {
            return XCTFail("Expected the highest valid glucose")
        }
        XCTAssertEqual(high.glucoseMgdL, 800)
    }
}

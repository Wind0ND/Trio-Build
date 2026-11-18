import Foundation
import XCTest

@testable import AiDEXKit

final class AiDEXProbeSessionTests: XCTestCase {
    private let serial = "SYNTHETIC-0001"
    private let peripheral = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let otherPeripheral = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private let frame1234: [UInt8] = [
        0x59, 0x00,
        0xD2, 0x04, 0x00, 0x11, 0x22, 0x78, 0x80,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x9B, 0x2B, 0xFE, 0xD1
    ]

    private let frame1235: [UInt8] = [
        0x59, 0x00,
        0xD3, 0x04, 0x00, 0x11, 0x22, 0x79, 0x80,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0xB4, 0xA7, 0xD0, 0xF2
    ]

    // Same fields as frame1234, status 1, independently calculated CRC.
    private let statusNotReadyFrame: [UInt8] = [
        0x59, 0x00,
        0xD2, 0x04, 0x01, 0x11, 0x22, 0x78, 0x80,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x6A, 0x78, 0xA4, 0x8C
    ]

    private func makeSession() throws -> AiDEXProbeSession {
        let session = try XCTUnwrap(AiDEXProbeSession(serial: serial))
        var started = session
        started.begin()
        return started
    }

    func testDuplicateFrameDoesNotRefreshAcceptedTimestamp() throws {
        var session = try makeSession()
        let first = session.receive(
            peripheralID: peripheral,
            localName: "AiDEX X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start
        )
        guard case let .accepted(reading)? = first.reading else {
            return XCTFail("Expected the first frame to be accepted")
        }
        XCTAssertTrue(first.matchedNow)
        XCTAssertEqual(reading.glucoseMgdL, 120)
        XCTAssertEqual(session.latest?.receivedAt, start)

        let duplicate = session.receive(
            peripheralID: peripheral,
            localName: nil,
            manufacturerData: Data(frame1234),
            at: start.addingTimeInterval(30)
        )
        guard case .duplicateOrOutOfOrder? = duplicate.reading else {
            return XCTFail("Repeated minute should be ignored")
        }
        XCTAssertEqual(session.latest?.receivedAt, start)
        XCTAssertEqual(session.latest?.glucoseMgdL, 120)
    }

    func testRegressingMinuteIsIgnored() throws {
        var session = try makeSession()
        _ = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1235),
            at: start
        )
        let prior = session.latest
        let regressing = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start.addingTimeInterval(300)
        )
        guard case .duplicateOrOutOfOrder? = regressing.reading else {
            return XCTFail("Older minute should be ignored")
        }
        XCTAssertEqual(session.latest, prior)
    }

    func testNewMinuteUpdatesValueAndTimestamp() throws {
        var session = try makeSession()
        _ = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start
        )
        let later = start.addingTimeInterval(300)
        let next = session.receive(
            peripheralID: peripheral,
            localName: nil,
            manufacturerData: Data(frame1235),
            at: later
        )
        guard case let .accepted(reading)? = next.reading else {
            return XCTFail("Expected a new minute to be accepted")
        }
        XCTAssertEqual(reading.glucoseMgdL, 121)
        XCTAssertEqual(reading.receivedAt, later)
        XCTAssertEqual(session.latest, reading)
    }

    func testLookalikeDeviceCannotBlockTheExactMatch() throws {
        var session = try makeSession()
        let first = session.receive(
            peripheralID: otherPeripheral,
            localName: "AiDEX X-\(serial)0",
            manufacturerData: nil,
            at: start
        )
        XCTAssertFalse(first.matchedNow)
        XCTAssertNil(session.latest)

        let exact = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start.addingTimeInterval(1)
        )
        XCTAssertTrue(exact.matchedNow)
        XCTAssertNotNil(session.latest)
    }

    func testSelectedSensorCarriesTheFiniteChecksumIssue() throws {
        var session = try makeSession()
        var corrupt = frame1234
        corrupt[21] ^= 0x01

        let result = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(corrupt),
            at: start
        )
        XCTAssertTrue(result.matchedNow)
        XCTAssertNil(result.reading)
        XCTAssertNil(session.latest)
        XCTAssertEqual(result.issue, .checksumMismatch)
    }

    func testSelectedSensorCarriesTheFiniteUnsupportedFrameIssue() throws {
        var session = try makeSession()
        var unsupported = frame1234
        unsupported[0] = 0x58

        let result = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(unsupported),
            at: start
        )
        XCTAssertTrue(result.matchedNow)
        XCTAssertNil(result.reading)
        XCTAssertNil(session.latest)
        XCTAssertEqual(result.issue, .unsupportedManufacturerFrame)
    }

    func testSelectedSensorCarriesTheFiniteReadingUnavailableIssue() throws {
        var session = try makeSession()
        let result = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(statusNotReadyFrame),
            at: start
        )
        XCTAssertTrue(result.matchedNow)
        XCTAssertNil(result.reading)
        XCTAssertNil(session.latest)
        XCTAssertEqual(result.issue, .readingUnavailable)
    }

    func testNormalScanResponseAndMissingManufacturerDataAreNotIssues() throws {
        var session = try makeSession()
        _ = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start
        )

        let scanResponse = session.receive(
            peripheralID: peripheral,
            localName: nil,
            manufacturerData: Data([0x59, 0x00, 0x03, 0x05, 0x06, 0x49, 0x37]),
            at: start.addingTimeInterval(1)
        )
        XCTAssertFalse(scanResponse.matchedNow)
        XCTAssertNil(scanResponse.reading)
        XCTAssertNil(scanResponse.issue)

        let noManufacturerData = session.receive(
            peripheralID: peripheral,
            localName: nil,
            manufacturerData: nil,
            at: start.addingTimeInterval(2)
        )
        XCTAssertNil(noManufacturerData.reading)
        XCTAssertNil(noManufacturerData.issue)
    }

    func testLookalikeDecodeFailureIsNotReported() throws {
        var session = try makeSession()
        var corrupt = frame1234
        corrupt[21] ^= 0x01

        let result = session.receive(
            peripheralID: otherPeripheral,
            localName: "X-\(serial)0",
            manufacturerData: Data(corrupt),
            at: start
        )
        XCTAssertFalse(result.matchedNow)
        XCTAssertNil(result.reading)
        XCTAssertNil(result.issue)
    }

    func testSecondMatchingPeripheralCannotInjectReadings() throws {
        var session = try makeSession()
        _ = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start
        )
        let before = session.latest

        let conflict = session.receive(
            peripheralID: otherPeripheral,
            localName: "AiDEX X-\(serial)",
            manufacturerData: Data(frame1235),
            at: start.addingTimeInterval(10)
        )
        XCTAssertTrue(conflict.conflictingDevice)
        XCTAssertNil(conflict.reading)
        XCTAssertEqual(session.latest, before)
    }

    func testCallbacksAfterStopAreIgnoredAndStateIsCleared() throws {
        var session = try makeSession()
        _ = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start
        )
        XCTAssertNotNil(session.latest)
        session.stop(.user)
        XCTAssertEqual(session.phase, .stopped(.user))
        XCTAssertNil(session.latest)

        let afterStop = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1235),
            at: start.addingTimeInterval(1)
        )
        XCTAssertFalse(afterStop.matchedNow)
        XCTAssertNil(afterStop.reading)
        XCTAssertNil(session.latest)
    }

    func testRestartDoesNotReuseTheOldSelectedPeripheralOrMinute() throws {
        var session = try makeSession()
        _ = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start
        )
        session.stop(.sceneInactive)
        session.begin()

        // Same minute from a new session is allowed again, and the old
        // peripheral selection does not linger.
        let restarted = session.receive(
            peripheralID: otherPeripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start.addingTimeInterval(5)
        )
        XCTAssertTrue(restarted.matchedNow)
        XCTAssertNotNil(session.latest)
    }

    func testDisappearanceStopsAfterTimeoutAndClearsReading() throws {
        var session = try makeSession()
        _ = session.receive(
            peripheralID: peripheral,
            localName: "X-\(serial)",
            manufacturerData: Data(frame1234),
            at: start
        )
        XCTAssertFalse(session.checkDisappearance(now: start.addingTimeInterval(59)))
        XCTAssertTrue(session.checkDisappearance(now: start.addingTimeInterval(60)))
        XCTAssertEqual(session.phase, .stopped(.disappeared))
        XCTAssertNil(session.latest)
    }

    func testDisappearanceDoesNotStopBeforeMatch() throws {
        var session = try makeSession()
        XCTAssertFalse(session.checkDisappearance(now: start.addingTimeInterval(3_600)))
    }

    func testStaleReadingUsesReceiveTimestampNotProtocolAge() throws {
        let reading = AiDEXAcceptedReading(
            glucoseMgdL: 120,
            activeMinutes: 1234,
            receivedAt: start
        )
        XCTAssertFalse(reading.isStale(at: start.addingTimeInterval(359)))
        XCTAssertTrue(reading.isStale(at: start.addingTimeInterval(360)))
        XCTAssertEqual(reading.glucoseMmolL, 120.0 / 18.0, accuracy: 0.0001)
    }
}

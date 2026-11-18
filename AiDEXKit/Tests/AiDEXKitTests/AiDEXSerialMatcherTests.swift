import Foundation
import XCTest

@testable import AiDEXKit

final class AiDEXSerialMatcherTests: XCTestCase {
    // Deliberately synthetic; never a real sensor serial.
    private let serial = "SYNTHETIC-0001"

    func testAcceptsOnlyTheTwoAllowedLocalNamePrefixes() throws {
        let matcher = try XCTUnwrap(AiDEXSerialMatcher(serial: serial))
        XCTAssertTrue(matcher.matches(localName: "AiDEX X-\(serial)"))
        XCTAssertTrue(matcher.matches(localName: "X-\(serial)"))
    }

    func testNormalizesCaseAndSurroundingWhitespace() throws {
        let matcher = try XCTUnwrap(AiDEXSerialMatcher(serial: "  synthetic-0001 \n"))
        XCTAssertTrue(matcher.matches(localName: "aidex x-synthetic-0001 "))
        XCTAssertTrue(matcher.matches(localName: " x-SYNTHETIC-0001\t"))
    }

    func testDoesNotAcceptLookalikesSubstringsOrMissingPrefixes() throws {
        let matcher = try XCTUnwrap(AiDEXSerialMatcher(serial: serial))
        XCTAssertFalse(matcher.matches(localName: "AiDEX X-\(serial)0"))
        XCTAssertFalse(matcher.matches(localName: "X-\(serial.prefix(serial.count - 1))"))
        XCTAssertFalse(matcher.matches(localName: "prefix X-\(serial)"))
        XCTAssertFalse(matcher.matches(localName: serial))
        XCTAssertFalse(matcher.matches(localName: nil))
        XCTAssertFalse(matcher.matches(localName: "X-"))
    }

    func testNormalizesSerialThatWasPastedWithAPrefix() throws {
        let matcher = try XCTUnwrap(AiDEXSerialMatcher(serial: "AiDEX X-\(serial)"))
        XCTAssertTrue(matcher.matches(localName: "X-\(serial)"))
    }

    func testRejectsBlankSerial() {
        XCTAssertNil(AiDEXSerialMatcher(serial: "   "))
        XCTAssertNil(AiDEXSerialMatcher(serial: "AiDEX X-   "))
    }
}

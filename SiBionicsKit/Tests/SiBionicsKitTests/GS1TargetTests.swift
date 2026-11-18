import XCTest
@testable import SiBionicsKit

final class GS1TargetTests: XCTestCase {
    func testExactIdentifierMatchesWithoutAdvertisedService() throws {
        let target = try XCTUnwrap(GS1Target(input: "abcd802j"))
        XCTAssertTrue(target.matches(localName: "ABCD802J", advertisesService: false))
        XCTAssertFalse(target.matches(localName: nil, advertisesService: true))
    }

    func testRecognizedShortCodePrefixRequiresService() throws {
        let target = try XCTUnwrap(GS1Target(input: "ABCD802J"))
        XCTAssertTrue(target.matches(localName: "ABCD802J01", advertisesService: true))
        XCTAssertFalse(target.matches(localName: "ABCD802J01", advertisesService: false))
        XCTAssertFalse(target.matches(localName: "XXABCD802J", advertisesService: true))
        XCTAssertFalse(target.matches(localName: "ABCD802J-ABC", advertisesService: true))
    }

    func testExplicitSerialRequiresExactMatch() throws {
        let target = try XCTUnwrap(GS1Target(input: "(21)TEST1234567"))
        XCTAssertTrue(target.matches(localName: "TEST1234567", advertisesService: true))
        XCTAssertFalse(target.matches(localName: "TEST12345670", advertisesService: true))
    }
}

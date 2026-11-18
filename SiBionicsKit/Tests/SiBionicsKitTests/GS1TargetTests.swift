import XCTest
@testable import SiBionicsKit

final class GS1TargetTests: XCTestCase {
    func testExactIdentifierMatches() throws {
        let target = try XCTUnwrap(GS1Target(input: "abcd802j"))
        XCTAssertTrue(target.matches(localName: "ABCD802J"))
        XCTAssertFalse(target.matches(localName: nil))
    }

    func testShortCodeCannotMatchByPrefix() throws {
        let target = try XCTUnwrap(GS1Target(input: "ABCD802J"))
        XCTAssertFalse(target.matches(localName: "ABCD802J01"))
        XCTAssertFalse(target.matches(localName: "XXABCD802J"))
        XCTAssertFalse(target.matches(localName: "ABCD802J-ABC"))
    }

    func testExplicitSerialRequiresExactMatch() throws {
        let target = try XCTUnwrap(GS1Target(input: "(21)TEST1234567"))
        XCTAssertTrue(target.matches(localName: "TEST1234567"))
        XCTAssertFalse(target.matches(localName: "TEST12345670"))
    }
}

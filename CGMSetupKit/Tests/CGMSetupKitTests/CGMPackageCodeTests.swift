import XCTest
@testable import CGMSetupKit

final class CGMPackageCodeTests: XCTestCase {
    func testExtractsPrintedAiDEXSerial() {
        XCTAssertEqual(CGMPackageCode.aiDEXSerial(from: "(01)06958590312864(11)260930(17)280129(10)LOT(21)TEST123456"), "TEST123456")
    }

    func testExtractsCompactGS1Serial() {
        XCTAssertEqual(CGMPackageCode.aiDEXSerial(from: "]d20106958590312864112609301728012910LOT\u{1D}21TEST123456"), "TEST123456")
    }

    func testRejectsIdentityFromLotOrAmbiguousCode() {
        XCTAssertNil(CGMPackageCode.aiDEXSerial(from: "010695859031286410LOT21TEST123456"))
        XCTAssertNil(CGMPackageCode.aiDEXSerial(from: "(21)TEST123456(21)WRONG12345"))
        XCTAssertNil(CGMPackageCode.aiDEXSerial(from: "https://example.invalid/TEST123456"))
    }

    func testValidatesGS1ConnectionCodeAndExplicitSerial() {
        XCTAssertEqual(CGMPackageCode.sibionicsIdentifier(from: " abcd802j "), "ABCD802J")
        XCTAssertEqual(CGMPackageCode.sibionicsIdentifier(from: "(21)TEST1234567"), "TEST1234567")
        XCTAssertNil(CGMPackageCode.sibionicsIdentifier(from: "(10)ABCD802J"))
        XCTAssertNil(CGMPackageCode.sibionicsIdentifier(from: "ABCD 802J"))
    }

    func testRejectsMalformedOrDuplicatePrintedFields() {
        XCTAssertNil(CGMPackageCode.aiDEXSerial(from: "(01)X(17)Q(21)TEST123456"))
        XCTAssertNil(CGMPackageCode.aiDEXSerial(from: "(11)260930(11)260931(21)TEST123456"))
        XCTAssertNil(CGMPackageCode.aiDEXSerial(from: "(10)012345678901234567890(21)TEST123456"))
    }
}

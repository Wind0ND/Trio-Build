import XCTest
@testable import PrivacyAppKit

final class PrivacyCredentialTests: XCTestCase {
    func testPINAndPatternValidation() {
        XCTAssertTrue(PrivacyLockMethod.pin.accepts("0123"))
        XCTAssertFalse(PrivacyLockMethod.pin.accepts("１２３４"))
        XCTAssertFalse(PrivacyLockMethod.pin.accepts("123"))
        XCTAssertTrue(PrivacyLockMethod.pattern.accepts("01258"))
        XCTAssertFalse(PrivacyLockMethod.pattern.accepts("0121"))
        XCTAssertFalse(PrivacyLockMethod.pattern.accepts("0129"))
    }

    func testSaltedCredentialRoundTripRejectsWrongSecret() throws {
        let first = try PrivacyCredential(method: .pin, secret: "0123")
        let second = try PrivacyCredential(method: .pin, secret: "0123")
        XCTAssertNotEqual(first.digest, second.digest)
        XCTAssertTrue(first.accepts("0123"))
        XCTAssertFalse(first.accepts("0124"))
        let decoded = try JSONDecoder().decode(PrivacyCredential.self, from: JSONEncoder().encode(first))
        XCTAssertTrue(decoded.accepts("0123"))
    }

    func testCooldownSurvivesSerializationAndIsBounded() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var attempts = PrivacyAttemptState()
        for _ in 0 ..< 5 { attempts.failed(at: now) }
        XCTAssertEqual(attempts.retryAfter.timeIntervalSince(now), 30)
        attempts = try JSONDecoder().decode(PrivacyAttemptState.self, from: JSONEncoder().encode(attempts))
        XCTAssertEqual(attempts.failures, 5)
        for _ in 0 ..< 200 { attempts.failed(at: now) }
        XCTAssertLessThanOrEqual(attempts.retryAfter.timeIntervalSince(now), 900)
    }
}

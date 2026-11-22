import Foundation
import MedtrumLifecycleKit
import XCTest

final class MedtrumCommandGateTests: XCTestCase {
    func testUnsentInvalidCommandIsRejected() {
        let gate = MedtrumCommandGate()
        var sent = false
        let result = gate.perform(isValid: { false }) { sent = true; return 1 }
        XCTAssertNil(result)
        XCTAssertFalse(sent)
    }

    func testValidationOccursAfterThePreviousCommandReleasesItsSlot() {
        let gate = MedtrumCommandGate()
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondFinished = expectation(description: "queued command rejected")
        DispatchQueue.global().async {
            _ = gate.perform(isValid: { true }) {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            let result = gate.perform(isValid: { false }) { 1 }
            XCTAssertNil(result)
            secondFinished.fulfill()
        }
        releaseFirst.signal()
        wait(for: [secondFinished], timeout: 5)
    }
}

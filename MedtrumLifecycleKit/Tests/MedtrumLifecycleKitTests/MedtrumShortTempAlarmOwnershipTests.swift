import XCTest
@testable import MedtrumLifecycleKit

final class MedtrumShortTempAlarmOwnershipTests: XCTestCase {
    func testLateSystemAcceptanceAfterResolveIsCleanupOnlyNotResurrection() throws {
        var ledger = MedtrumShortTempAlarmOwnership()
        let command = UUID()
        let ticket = try XCTUnwrap(ledger.reserve(commandID: command, deadline: Date().addingTimeInterval(75)))
        _ = ledger.resolve(command)
        XCTAssertFalse(ledger.accept(ticket))
        XCTAssertTrue(ledger.activeTickets(command).isEmpty)
        XCTAssertTrue(ledger.cleanupTickets.contains { $0.id == ticket.id })
    }

    func testReplacingOrFailedReplacementKeepsAlreadyAcceptedBackup() throws {
        var ledger = MedtrumShortTempAlarmOwnership()
        let command = UUID()
        let first = try XCTUnwrap(ledger.reserve(commandID: command, deadline: Date().addingTimeInterval(75)))
        let backup = try XCTUnwrap(ledger.reserve(commandID: command, deadline: Date().addingTimeInterval(135)))
        XCTAssertTrue(ledger.accept(first))
        XCTAssertTrue(ledger.accept(backup))
        let replacement = try XCTUnwrap(ledger.reserve(commandID: command, deadline: Date().addingTimeInterval(2)))
        ledger.cancelled(replacement)
        XCTAssertEqual(Set(ledger.activeTickets(command).map(\.id)), Set([first.id, backup.id]))
        XCTAssertNotEqual(first.id, replacement.id)
        XCTAssertEqual(first.generation, backup.generation)
    }

    func testPersistedOwnershipAndResolvedTombstoneSurviveRestart() throws {
        var ledger = MedtrumShortTempAlarmOwnership()
        let command = UUID()
        let ticket = try XCTUnwrap(ledger.reserve(commandID: command, deadline: Date().addingTimeInterval(75)))
        XCTAssertTrue(ledger.accept(ticket))
        var restored = try JSONDecoder().decode(MedtrumShortTempAlarmOwnership.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.owner(of: ticket.id), command)
        XCTAssertEqual(restored.resolve(command).map(\.id), [ticket.id])
        XCTAssertTrue(restored.isResolved(command))
        XCTAssertNil(restored.reserve(commandID: command, deadline: Date().addingTimeInterval(100)))
        restored.cancelled(ticket)
        XCTAssertTrue(restored.cleanupTickets.isEmpty)
    }
}

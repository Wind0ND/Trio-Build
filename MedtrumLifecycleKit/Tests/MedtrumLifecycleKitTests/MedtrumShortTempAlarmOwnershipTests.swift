import XCTest
@testable import MedtrumLifecycleKit

final class MedtrumShortTempAlarmOwnershipTests: XCTestCase {
    func testLongIncidentKeepsNewestSoundAndFutureGuardsWithoutAccumulatingElapsedTickets() throws {
        var ledger = MedtrumShortTempAlarmOwnership()
        let command = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        var tickets: [MedtrumShortTempAlarmOwnership.Ticket] = []
        for offset in [-120.0, -60, -1, 30, 90] {
            let ticket = try XCTUnwrap(ledger.reserve(commandID: command, deadline: now.addingTimeInterval(offset)))
            XCTAssertTrue(ledger.accept(ticket))
            tickets.append(ticket)
        }
        let cleanup = ledger.supersededElapsedTickets(command, at: now)
        XCTAssertEqual(Set(cleanup.map(\.id)), Set(tickets.prefix(2).map(\.id)))
        for ticket in cleanup { ledger.cancelled(ticket) }
        XCTAssertEqual(Set(ledger.activeTickets(command).map(\.id)), Set(tickets.suffix(3).map(\.id)))
        XCTAssertFalse(ledger.isResolved(command))
    }
    func testStoppingSoundPreservesOwnershipAndAbsoluteRepeatWindow() throws {
        var ledger = MedtrumShortTempAlarmOwnership()
        let command = UUID()
        let ticket = try XCTUnwrap(ledger.reserve(commandID: command, deadline: Date().addingTimeInterval(75)))
        XCTAssertTrue(ledger.accept(ticket))
        let repeatAt = Date().addingTimeInterval(60)
        ledger.recordStop(command, until: repeatAt)
        let restored = try JSONDecoder().decode(MedtrumShortTempAlarmOwnership.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(restored.isResolved(command))
        XCTAssertEqual(restored.activeTickets(command).count, 1)
        XCTAssertEqual(restored.nextWarningNotBefore(command), repeatAt)
    }

    func testAuthorizationAndTicketExpiryAreCheckedByFinalWriteGate() {
        let gate = MedtrumShortTempAlarmReadiness()
        let command = UUID()
        let now = Date()
        gate.replace(authorized: true, deadlines: [command: now.addingTimeInterval(75)])
        XCTAssertTrue(gate.permits(command, at: now))
        XCTAssertFalse(gate.permits(UUID(), at: now))
        gate.replace(authorized: false, deadlines: [command: now.addingTimeInterval(75)])
        XCTAssertFalse(gate.permits(command, at: now))
        gate.replace(authorized: true, deadlines: [command: now.addingTimeInterval(-1)])
        XCTAssertFalse(gate.permits(command, at: now))
    }

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

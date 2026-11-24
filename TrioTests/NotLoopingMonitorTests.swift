import Combine
import Foundation
import LoopKit
import Testing
import UserNotifications

@testable import Trio

/// Records `issueAlert` / `retractAlert` calls in order so tests can assert
/// the retract-then-issue re-arm semantics of `NotLoopingMonitor`. Every
/// other `TrioAlertManager` member is a no-op stub.
final class SpyAlertManager: TrioAlertManager {
    enum Call: Equatable {
        case retract(Alert.Identifier)
        case issue(Alert)
    }

    private(set) var callLog: [Call] = []
    private(set) var issuedAlerts: [Alert] = []
    private(set) var retractedIdentifiers: [Alert.Identifier] = []

    func issueAlert(_ alert: Alert) {
        callLog.append(.issue(alert))
        issuedAlerts.append(alert)
    }

    func retractAlert(identifier: Alert.Identifier) {
        callLog.append(.retract(identifier))
        retractedIdentifiers.append(identifier)
    }

    // MARK: - No-op stubs

    func register(responder _: AlertResponder, for _: String) {}
    func register(soundVendor _: AlertSoundVendor, for _: String) {}
    func unregister(managerIdentifier _: String) {}

    func handleAcknowledgement(identifier _: Alert.Identifier) {}
    @MainActor func handleNotificationResponse(_: UNNotificationResponse) {}
    @MainActor func handleWatchSnooze(_: AlertNotificationSnooze) {}
    func acknowledgeAllOutstanding() {}
    func replayUnacknowledgedAlerts() {}
    @MainActor func applySnooze(for _: TimeInterval) async {}
    func clearPendingNonCriticalNotifications() {}

    var muter: AlertMuter { AlertMuter() }
    let modalScheduler = TrioModalAlertScheduler()

    func soundURL(for _: Alert) -> URL? { nil }
}

@Suite("Trio Alerts: NotLoopingMonitor") struct NotLoopingMonitorTests {
    @Test("Starting manual basal withdraws plans and ending gives a fresh recovery window")
    func manualBasalWithdrawsAndRecovers() {
        let dates = PassthroughSubject<Date, Never>()
        let manual = PassthroughSubject<Bool, Never>()
        let spy = SpyAlertManager()
        let clock = Date()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy,
                                       manualTempBasal: manual.eraseToAnyPublisher(), now: { clock })
        dates.send(clock.addingTimeInterval(-10 * 60))
        let before = spy.retractedIdentifiers.count
        manual.send(true)
        #expect(spy.retractedIdentifiers.count == before + 6)
        let issued = spy.issuedAlerts.count
        dates.send(clock)
        #expect(spy.issuedAlerts.count == issued)
        manual.send(false)
        #expect(spy.issuedAlerts.count == issued + 6)
        if let warning = spy.issuedAlerts.last(where: { $0.identifier == warningID(1) }) {
            expectDelay(warning.trigger, 20)
        }
        let after = spy.callLog.count
        manual.send(false)
        #expect(spy.callLog.count == after)
        _ = monitor
    }

    @Test("Recovery anchor persists and duplicate inactive status cannot reset it")
    func recoveryWindowSurvivesRestart() throws {
        let name = "LoopRecoveryTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let success = start.addingTimeInterval(-600)
        let window = HiroLoopReminderWindow(defaults: defaults)
        #expect(window.setManualTempBasal(true, at: start))
        #expect(window.manualActive)
        #expect(HiroLoopReminderWindow(defaults: defaults).manualActive)
        let end = start.addingTimeInterval(1200)
        #expect(window.setManualTempBasal(false, at: end))
        #expect(window.anchor(lastSuccess: success) == end)
        let restored = HiroLoopReminderWindow(defaults: defaults)
        #expect(!restored.setManualTempBasal(false, at: end.addingTimeInterval(600)))
        #expect(restored.anchor(lastSuccess: success) == end)
        #expect(restored.anchor(lastSuccess: end.addingTimeInterval(30)) == end.addingTimeInterval(30))
    }

    @Test("Manual state cannot re-arm a disabled reminder")
    func disabledManualRecoveryDoesNotArm() {
        let dates = PassthroughSubject<Date, Never>()
        let manual = PassthroughSubject<Bool, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy,
                                       remindersEnabled: Just(false).eraseToAnyPublisher(),
                                       manualTempBasal: manual.eraseToAnyPublisher())
        dates.send(Date())
        manual.send(true)
        manual.send(false)
        #expect(spy.issuedAlerts.isEmpty)
        _ = monitor
    }

    @Test("Ending manual basal during suspension re-arms once when the pump resumes")
    func manualEndDuringSuspensionRecovers() {
        let dates = PassthroughSubject<Date, Never>()
        let manual = PassthroughSubject<Bool, Never>()
        let suspended = PassthroughSubject<Bool, Never>()
        let spy = SpyAlertManager()
        var clock = Date()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy,
                                       manualTempBasal: manual.eraseToAnyPublisher(), suspended: suspended.eraseToAnyPublisher(),
                                       now: { clock })
        dates.send(clock.addingTimeInterval(-130 * 60))
        manual.send(true)
        suspended.send(true)
        manual.send(false)
        #expect(spy.issuedAlerts.isEmpty)
        clock = clock.addingTimeInterval(300)
        suspended.send(false)
        #expect(spy.issuedAlerts.count == 6)
        if let warning = spy.issuedAlerts.first { expectDelay(warning.trigger, 20) }
        let count = spy.callLog.count
        suspended.send(false)
        manual.send(false)
        #expect(spy.callLog.count == count)
        _ = monitor
    }
    /// Reconstructed locally from the private statics in the source.
    private let criticalID = Alert.Identifier(
        managerIdentifier: "trio.aps",
        alertIdentifier: "loop.notActive"
    )
    private func warningID(_ step: Int) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: "loop.notActive.w\(step)")
    }

    /// Steps are anchored to the last loop date, so the armed interval is a
    /// few milliseconds short of the nominal value by the time it is built.
    private func expectDelay(_ trigger: Alert.Trigger, _ minutes: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .delayed(interval) = trigger else {
            Issue.record("expected a delayed trigger, got \(trigger)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(interval - TimeInterval(minutes * 60)) < 5, sourceLocation: sourceLocation)
    }

    private func armLadder() -> SpyAlertManager {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: subject.eraseToAnyPublisher(), trioAlertManager: spy)
        subject.send(Date())
        _ = monitor // retain through the synchronous send
        return spy
    }

    @Test("The loop reminder defaults on and preserves an explicit opt-out across restart")
    func reminderChoiceSurvivesRestart() throws {
        let name = "LoopReminderTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HiroLoopReminderPreferences(defaults: defaults)
        #expect(store.enabled)
        store.enabled = false
        #expect(!store.allows(criticalID))
        for step in 1 ... 5 { #expect(!store.allows(warningID(step))) }
        #expect(store.allows(Alert.Identifier(managerIdentifier: "Medtrum", alertIdentifier: "occlusion")))
        #expect(!HiroLoopReminderPreferences(defaults: defaults).enabled)
    }

    @Test("Disabling the loop reminder retracts the entire ladder without disabling other alerts")
    func disablingReminderClearsPlans() {
        let dates = PassthroughSubject<Date, Never>()
        let enabled = CurrentValueSubject<Bool, Never>(false)
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy,
                                       remindersEnabled: enabled.eraseToAnyPublisher())
        dates.send(Date())
        #expect(spy.issuedAlerts.isEmpty)
        enabled.send(true)
        #expect(spy.issuedAlerts.count == 6)
        enabled.send(false)
        let count = spy.issuedAlerts.count
        dates.send(Date())
        #expect(spy.issuedAlerts.count == count)
        #expect(spy.retractedIdentifiers.suffix(6).allSatisfy { $0.managerIdentifier == "trio.aps" })
        _ = monitor
    }

    @Test("Unrelated settings do not retract overdue or outstanding reminders")
    func unrelatedSettingsPreserveOutstandingReminders() {
        let dates = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy)
        dates.send(Date().addingTimeInterval(-130 * 60))
        let before = spy.retractedIdentifiers.count
        monitor.settingsDidChange(TrioSettings(dosingMode: .closed))
        monitor.settingsDidChange(TrioSettings(dosingMode: .closed, debugOptions: true))
        #expect(spy.retractedIdentifiers.count == before)
    }

    @Test("Re-enabling reminders when already overdue arms the critical escalation immediately")
    func enablingOverdueReminderArmsCritical() {
        let dates = PassthroughSubject<Date, Never>()
        let enabled = CurrentValueSubject<Bool, Never>(false)
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy,
                                       remindersEnabled: enabled.eraseToAnyPublisher())
        dates.send(Date().addingTimeInterval(-130 * 60))
        enabled.send(true)
        #expect(spy.issuedAlerts.count == 1)
        #expect(spy.issuedAlerts.first?.identifier == criticalID)
        #expect(spy.issuedAlerts.first?.trigger == .immediate)
        _ = monitor
    }

    @Test("An enabled startup subscription preserves existing OS alarms and unresolved history")
    func enabledStartupDoesNotClearExistingAlarms() {
        let dates = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy)
        #expect(spy.retractedIdentifiers.isEmpty)
        #expect(spy.issuedAlerts.isEmpty)
        _ = monitor
    }

    @Test("Snoozing another alert in open loop cannot arm the automated-loop watchdog")
    @MainActor func openLoopSnoozeDoesNotArmWatchdog() {
        let dates = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: dates.eraseToAnyPublisher(), trioAlertManager: spy)
        monitor.settingsDidChange(TrioSettings(dosingMode: .open))
        dates.send(Date())
        monitor.snoozeDidChange(Date().addingTimeInterval(900))
        #expect(spy.issuedAlerts.isEmpty)
    }

    @Test("A loop success arms five warnings and one critical") func armsFullLadder() {
        let spy = armLadder()
        #expect(spy.issuedAlerts.count == 6)

        let warnings = spy.issuedAlerts.filter { $0.identifier != criticalID }
        #expect(warnings.count == 5)
        for (index, minutes) in [20, 40, 60, 80, 100].enumerated() {
            let alert = warnings[index]
            #expect(alert.identifier == warningID(index + 1))
            expectDelay(alert.trigger, minutes)
            #expect(alert.interruptionLevel == .timeSensitive)
        }
    }

    @Test("The sixth step is critical at 120 minutes") func criticalStepAtTwoHours() {
        let spy = armLadder()
        guard let critical = spy.issuedAlerts.first(where: { $0.identifier == criticalID }) else {
            Issue.record("expected a critical escalation alert")
            return
        }
        expectDelay(critical.trigger, 120)
        #expect(critical.interruptionLevel == .critical)
    }

    @Test("Every step is retracted before anything is re-armed") func retractsWholeLadderFirst() {
        let spy = armLadder()
        let firstIssue = spy.callLog.firstIndex { if case .issue = $0 { return true }
            return false }
        let lastRetract = spy.callLog.lastIndex { if case .retract = $0 { return true }
            return false }
        guard let firstIssue, let lastRetract else {
            Issue.record("expected both retracts and issues")
            return
        }
        #expect(lastRetract < firstIssue)
        #expect(spy.retractedIdentifiers.count == 6)
        #expect(Set(spy.retractedIdentifiers) == Set([criticalID] + (1 ... 5).map(warningID)))
    }

    @Test("A recovered loop re-arms the whole ladder again") func reArmsOnEachSuccess() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: subject.eraseToAnyPublisher(), trioAlertManager: spy)

        subject.send(Date())
        subject.send(Date())

        #expect(spy.issuedAlerts.count == 12)
        #expect(spy.retractedIdentifiers.count == 12)
        _ = monitor
    }

    @Test("Warning identifiers resolve to the Time-Sensitive tier") func warningsAreCatalogedTimeSensitive() {
        for step in 1 ... 5 {
            guard let entry = AlertCatalogRegistry.lookup(warningID(step)) else {
                Issue.record("warning step \(step) has no catalog entry")
                return
            }
            #expect(entry.interruptionLevel == .timeSensitive)
            #expect(entry.concept == .notLooping)
        }
        #expect(AlertCatalogRegistry.lookup(criticalID)?.interruptionLevel == .critical)
    }

    @Test("Every step is delayed, never immediate") func allStepsDelayed() {
        for alert in armLadder().issuedAlerts {
            #expect(alert.trigger != .immediate)
        }
    }
}

private actor RetryCounter {
    var count = 0
    func increment() { count += 1 }
}

@Suite("Loop guard deferred recovery") struct LoopGuardRecoveryTests {
    @Test("An early request is retained until the unchanged three-minute boundary", arguments: [159.0, 174.0])
    func earlyRequestRetained(offset: Double) async {
        let guardState = LoopGuard()
        let start = Date()
        let accepted = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                                    lastLoopStartDate: start, now: start.addingTimeInterval(offset), retry: {})
        #expect(!accepted)
        #expect(await guardState.pendingRetryDate == start.addingTimeInterval(180))
        await guardState.cancelPendingRetry()
        #expect(await guardState.pendingRetryDate == nil)
    }

    @Test("Repeated early requests coalesce into a single retry")
    func repeatedRequestsCoalesce() async throws {
        let counter = RetryCounter()
        let guardState = LoopGuard(retrySleep: { _ in try await Task.sleep(nanoseconds: 20_000_000) })
        let start = Date()
        for _ in 0 ..< 5 {
            let accepted = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                                        lastLoopStartDate: start, now: start.addingTimeInterval(170),
                                                        retry: { Task { await counter.increment() } })
            #expect(!accepted)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await counter.count == 1)
        #expect(await guardState.pendingRetryDate == nil)
    }

    @Test("A normal start cancels an obsolete retry and concurrent requests cannot start")
    func normalStartCancelsRetry() async throws {
        let counter = RetryCounter()
        let guardState = LoopGuard(retrySleep: { _ in try await Task.sleep(nanoseconds: 40_000_000) })
        let start = Date()
        _ = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                          lastLoopStartDate: start, now: start.addingTimeInterval(170),
                                          retry: { Task { await counter.increment() } })
        let accepted = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                                    lastLoopStartDate: start, now: start.addingTimeInterval(181), retry: {})
        #expect(accepted)
        #expect(await guardState.pendingRetryDate == nil)
        let duplicate = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                                     lastLoopStartDate: start, now: start.addingTimeInterval(182), retry: {})
        #expect(!duplicate)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await counter.count == 0)
        await guardState.finish()
    }

    @Test("A disabled automatic recovery cancels pending work without changing the minimum interval")
    func disabledRecoveryClearsPendingWork() async throws {
        let counter = RetryCounter()
        let guardState = LoopGuard(retrySleep: { _ in try await Task.sleep(nanoseconds: 40_000_000) })
        let start = Date()
        _ = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                          lastLoopStartDate: start, now: start.addingTimeInterval(159),
                                          retry: { Task { await counter.increment() } })
        let accepted = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                                    lastLoopStartDate: start, now: start.addingTimeInterval(160), retry: {},
                                                    allowsRetry: false)
        #expect(!accepted)
        #expect(await guardState.pendingRetryDate == nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await counter.count == 0)
        let atBoundary = await guardState.requestStart(minInterval: 180, lastLoopDate: start.addingTimeInterval(2),
                                                      lastLoopStartDate: start, now: start.addingTimeInterval(180), retry: {})
        #expect(atBoundary)
        await guardState.finish()
    }
}

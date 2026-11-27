import Foundation
import LoopKit
import PrivacyKit
import Testing
import UserNotifications
import SwiftUI
import Swinject

@testable import Trio

@MainActor @Suite("Alert notification history navigation") struct HiroAlertNotificationNavigationTests {
    @Test("Responses arriving before services initialize are replayed exactly once") func serviceHandoff() {
        let handoff = HiroNotificationResponseHandoff<String>()
        var delivered: [String] = []
        handoff.receive("default tap")
        handoff.receive("snooze action")
        #expect(delivered.isEmpty)
        handoff.attach { delivered.append($0) }
        #expect(delivered == ["default tap", "snooze action"])
        handoff.attach { delivered.append($0) }
        #expect(delivered.count == 2)
        handoff.receive("dismiss action")
        #expect(delivered == ["default tap", "snooze action", "dismiss action"])
    }

    @Test("Only a normal recognized alert tap opens history") func recognizeTap() {
        let payload: [AnyHashable: Any] = [AlertUserInfoKey.managerIdentifier.rawValue: "Medtrum",
                                          AlertUserInfoKey.alertIdentifier.rawValue: "shortTempBasalCancellationFailed"]
        #expect(HiroAlertHistoryNavigation.shouldOpenHistory(actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "alert", userInfo: payload))
        #expect(HiroAlertHistoryNavigation.shouldOpenHistory(actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "alert", userInfo: [AlertUserInfoKey.occurrence.rawValue: UUID().uuidString]))
        #expect(HiroAlertHistoryNavigation.shouldOpenHistory(actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "background-keep-alive-stall", userInfo: [:]))
        for action in [UNNotificationDismissActionIdentifier, "unknown"] + NotificationResponseAction.allCases.map(\.rawValue) {
            #expect(!HiroAlertHistoryNavigation.shouldOpenHistory(actionIdentifier: action, requestIdentifier: "alert", userInfo: payload))
        }
        let invalidPayloads: [[AnyHashable: Any]] = [[:], [AlertUserInfoKey.managerIdentifier.rawValue: "Medtrum"],
            [AlertUserInfoKey.occurrence.rawValue: "invalid"], [AlertUserInfoKey.managerIdentifier.rawValue: "", AlertUserInfoKey.alertIdentifier.rawValue: ""]]
        for invalid in invalidPayloads {
            #expect(!HiroAlertHistoryNavigation.shouldOpenHistory(actionIdentifier: UNNotificationDefaultActionIdentifier,
                requestIdentifier: "unrelated", userInfo: invalid))
        }
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Cold taps wait for configured root and coalesce") func coldStart() async {
        let navigation = HiroAlertHistoryNavigation()
        var opened = 0
        navigation.request()
        navigation.request()
        await nextMainTurn()
        #expect(opened == 0)
        navigation.attach(owner: UUID()) { opened += 1 }
        #expect(opened == 0, "Root subscriptions must be installed before dispatch")
        await nextMainTurn()
        #expect(opened == 1)
        navigation.request()
        await nextMainTurn()
        #expect(opened == 2)
    }

    @Test("Detaching a replaced root cannot remove the new router") func rootReplacement() async {
        let navigation = HiroAlertHistoryNavigation()
        let old = UUID(), current = UUID()
        var oldOpened = 0, currentOpened = 0
        navigation.attach(owner: old) { oldOpened += 1 }
        navigation.request()
        navigation.attach(owner: current) { currentOpened += 1 }
        navigation.detach(owner: old)
        await nextMainTurn()
        #expect(oldOpened == 0)
        #expect(currentOpened == 1)
        navigation.detach(owner: current)
        navigation.request()
        await nextMainTurn()
        #expect(currentOpened == 1)
        navigation.attach(owner: UUID()) { currentOpened += 1 }
        await nextMainTurn()
        #expect(currentOpened == 2)
    }

    @Test("History uses the existing modal destination and replaces secondary presentation") func routerDestination() async {
        let router = BaseRouter(resolver: Container())
        router.mainSecondaryModalView.send(AnyView(Text("Other")))
        let navigation = HiroAlertHistoryNavigation()
        navigation.request()
        navigation.attach(owner: UUID()) {
            router.mainSecondaryModalView.send(nil)
            router.mainModalScreen.send(.alertJournal)
        }
        await nextMainTurn()
        #expect(router.mainSecondaryModalView.value == nil)
        if case .alertJournal? = router.mainModalScreen.value {} else { Issue.record("Expected existing Alert History screen") }
    }
}

@Suite("Trio Alerts: dismissing an alert snoozes it") struct AlertDismissalSnoozeTests {
    @Test("Cold-start Watch routing cannot snooze an older occurrence after its replacement was acknowledged")
    func supersededWatchAlert() {
        let now = Date()
        let id = LoopKit.Alert.Identifier(managerIdentifier: "Trio", alertIdentifier: "glucose.low.a")
        let old = JournalAlert(source: "Trio", kind: id.alertIdentifier, title: "", body: "", issuedAt: now.addingTimeInterval(-30))
        var newest = JournalAlert(source: "Trio", kind: id.alertIdentifier, title: "", body: "", issuedAt: now)
        let other = JournalAlert(source: "other", kind: id.alertIdentifier, title: "", body: "", issuedAt: now.addingTimeInterval(30))
        #expect(BaseTrioAlertManager.latestOpenOccurrence(for: id, in: [newest, old, other]) == newest.id)
        newest.acknowledgedAt = now
        #expect(BaseTrioAlertManager.latestOpenOccurrence(for: id, in: [old, other, newest]) == nil)
    }

    @Test("A queued Watch action retains its occurrence and absolute expiry, with a phone-side critical cap")
    func queuedWatchSnooze() throws {
        let tap = Date(timeIntervalSince1970: 100_000)
        let occurrence = UUID()
        let content = UNMutableNotificationContent()
        content.userInfo = [AlertUserInfoKey.managerIdentifier.rawValue: "Trio", AlertUserInfoKey.alertIdentifier.rawValue: "glucose.high.a",
                            AlertUserInfoKey.occurrence.rawValue: occurrence.uuidString]
        let request = try #require(AlertNotificationSnooze(content: content, action: .snooze6hr, at: tap))
        let decoded = try PropertyListDecoder().decode(AlertNotificationSnooze.self, from: PropertyListEncoder().encode(request))
        #expect(decoded.managerIdentifier == "Trio")
        #expect(decoded.alertIdentifier == "glucose.high.a")
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: true, now: tap.addingTimeInterval(600)) == tap.addingTimeInterval(900))
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: false, now: tap.addingTimeInterval(600)) == tap.addingTimeInterval(21_600))
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: true, now: tap.addingTimeInterval(900)) == nil)
        #expect(decoded.until(currentOccurrence: UUID(), isCritical: true, now: tap) == nil)
        #expect(decoded.until(currentOccurrence: nil, isCritical: false, now: tap) == nil)
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: false, now: tap.addingTimeInterval(-3600)) == nil)
        content.userInfo.removeValue(forKey: AlertUserInfoKey.occurrence.rawValue)
        #expect(AlertNotificationSnooze(content: content, action: .snooze15, at: tap) == nil)
    }

    @Test("Critical and urgent-low notifications offer and accept only the short snooze")
    func criticalActions() {
        let quick = NotificationCategoryIdentifier.quickSnoozeOnly
        #expect(NotificationCategoryFactory.makeCategory(quick).actions.map(\.identifier) == ["Trio.snooze15"])
        #expect(quick.limitSnooze(6 * 3600) == 900)
        #expect(NotificationCategoryIdentifier.trioAlert.limitSnooze(6 * 3600) == 6 * 3600)
        #expect(NotificationCategoryIdentifier.alert(isCritical: false, slug: "glucose.urgentLow.uuid") == quick)
        #expect(NotificationCategoryIdentifier.alert(isCritical: true, slug: "someOtherAlert") == quick)
        #expect(NotificationCategoryIdentifier.alert(isCritical: false, slug: "glucose.low.uuid") == .trioAlert)
    }

    /// The bug this covers: tapping a High notification acknowledged it
    /// outright, and the alarm then stayed silent for the rest of the
    /// excursion. Every way of clearing an alert has to buy a snooze.
    @Test("Tapping a notification snoozes for 15 minutes") func tapSnoozes() {
        #expect(
            BaseTrioAlertManager.snoozeDuration(forActionIdentifier: UNNotificationDefaultActionIdentifier)
                == 15 * 60
        )
    }

    @Test("Swiping a notification away snoozes for 15 minutes") func swipeSnoozes() {
        #expect(
            BaseTrioAlertManager.snoozeDuration(forActionIdentifier: UNNotificationDismissActionIdentifier)
                == 15 * 60
        )
    }

    /// These buttons used to fall through to a plain acknowledgement, so
    /// picking "Snooze 3 hrs" did the same thing as picking OK.
    @Test("A chosen snooze action keeps its own duration") func chosenDurationWins() {
        #expect(BaseTrioAlertManager.snoozeDuration(forActionIdentifier: "Trio.snooze15") == 15 * 60)
        #expect(BaseTrioAlertManager.snoozeDuration(forActionIdentifier: "Trio.snooze1hr") == 60 * 60)
        #expect(BaseTrioAlertManager.snoozeDuration(forActionIdentifier: "Trio.snooze3hr") == 3 * 60 * 60)
        #expect(BaseTrioAlertManager.snoozeDuration(forActionIdentifier: "Trio.snooze6hr") == 6 * 60 * 60)
    }

    @Test("Every snooze action maps to its own duration") func everyActionMaps() {
        for action in NotificationResponseAction.allCases {
            #expect(BaseTrioAlertManager.snoozeDuration(forActionIdentifier: action.rawValue) == action.duration)
        }
    }

    /// An action Trio doesn't know still has to leave the alarm able to
    /// return, so it takes the quick snooze rather than silencing anything.
    @Test("An unknown action falls back to the quick snooze") func unknownActionFallsBack() {
        #expect(BaseTrioAlertManager.snoozeDuration(forActionIdentifier: "something.else") == 15 * 60)
    }

    @Test("The quick snooze is the 15-minute action, not a second constant") func oneSourceOfTruth() {
        #expect(BaseTrioAlertManager.quickSnooze == NotificationResponseAction.snooze15.duration)
    }

    @Test("An explicit long snooze of a type caps each critical sibling at fifteen minutes")
    func criticalSibling() {
        let now = Date()
        let until = now.addingTimeInterval(6 * 3600)
        var alarm = GlucoseAlert(type: .high)
        #expect(alarm.snoozeEnd(until, now: now) == until)
        alarm.overridesSilenceAndDND = true
        #expect(alarm.snoozeEnd(until, now: now) == now.addingTimeInterval(900))
        var urgentLow = GlucoseAlert(type: .urgentLow)
        urgentLow.overridesSilenceAndDND = false
        #expect(urgentLow.snoozeEnd(until, now: now) == now.addingTimeInterval(900))
    }

    @Test("The two-hour critical fallback request is audible until AlarmKit owns its sound")
    func delayedAlarmFallback() {
        let content = LoopKit.Alert.Content(title: "Overdue", body: "Two hours", acknowledgeActionButtonLabel: "OK")
        let alert = LoopKit.Alert(identifier: .init(managerIdentifier: "trio.aps", alertIdentifier: "loop.notActive"),
                                  foregroundContent: content, backgroundContent: content, trigger: .delayed(interval: 7200),
                                  interruptionLevel: .critical, sound: .sound(name: "honk.caf"))
        let scheduler = TrioUserNotificationAlertScheduler(notificationCenter: .current())
        let fallback = scheduler.makeRequest(alert: alert, soundURL: nil, silenced: false)
        #expect(fallback.content.sound != nil)
        #expect(fallback.content.interruptionLevel == .critical)
        #expect((fallback.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 7200)
        #expect(fallback.content.categoryIdentifier == NotificationCategoryIdentifier.quickSnoozeOnly.rawValue)
    }
}

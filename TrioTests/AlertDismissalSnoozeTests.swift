import Foundation
import LoopKit
import Testing
import UserNotifications

@testable import Trio

@Suite("Trio Alerts: dismissing an alert snoozes it") struct AlertDismissalSnoozeTests {
    @Test("A queued Watch action retains its occurrence and absolute expiry, with a phone-side critical cap")
    func queuedWatchSnooze() throws {
        let tap = Date(timeIntervalSince1970: 100_000)
        let occurrence = UUID()
        let content = UNMutableNotificationContent()
        content.userInfo = [AlertUserInfoKey.managerIdentifier.rawValue: "Trio", AlertUserInfoKey.alertIdentifier.rawValue: "glucose.high.a",
                            AlertUserInfoKey.occurrence.rawValue: occurrence.uuidString]
        let request = try #require(WatchAlertSnooze(content: content, action: .snooze6hr, at: tap))
        let decoded = try PropertyListDecoder().decode(WatchAlertSnooze.self, from: PropertyListEncoder().encode(request))
        #expect(decoded.managerIdentifier == "Trio")
        #expect(decoded.alertIdentifier == "glucose.high.a")
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: true, now: tap.addingTimeInterval(600)) == tap.addingTimeInterval(900))
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: false, now: tap.addingTimeInterval(600)) == tap.addingTimeInterval(21_600))
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: true, now: tap.addingTimeInterval(900)) == nil)
        #expect(decoded.until(currentOccurrence: UUID(), isCritical: true, now: tap) == nil)
        #expect(decoded.until(currentOccurrence: nil, isCritical: false, now: tap) == nil)
        #expect(decoded.until(currentOccurrence: occurrence, isCritical: false, now: tap.addingTimeInterval(-3600)) == nil)
        content.userInfo.removeValue(forKey: AlertUserInfoKey.occurrence.rawValue)
        #expect(WatchAlertSnooze(content: content, action: .snooze15, at: tap) == nil)
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

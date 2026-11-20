import Foundation
import PrivacyKit
import UIKit
import UserNotifications

/// Private on-device audit; independent of the active queue and redacted diagnostics.
final class HiroAlertJournal: @unchecked Sendable {
    static let shared = HiroAlertJournal()
    static let changed = Notification.Name("com.hiro.alertJournal.changed")
    private let repository: AlertJournalRepository
    private var observer: NSObjectProtocol?
    var unavailable: Bool { repository.unavailable }

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HiroExtensions", isDirectory: true)
        let url = folder.appendingPathComponent("alert-journal.json")
        repository = AlertJournalRepository(read: {
            do { return try Data(contentsOf: url) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        }, write: { data in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var target = url; try target.setResourceValues(excluded)
        })
        observer = Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.repository.retry(); self?.notify() }
    }

    deinit { if let observer { Foundation.NotificationCenter.default.removeObserver(observer) } }
    func recent() -> [JournalAlert] { repository.recent(now: Date()) }
    func issue(_ entry: JournalAlert) { let now = Date(); update { $0.issue(entry, now: now) } }
    func acknowledge(source: String, kind: String) {
        let now = Date(); update { $0.acknowledge(source: source, kind: kind, at: now) }
    }
    func resolve(source: String, kind: String) {
        let now = Date(); update { $0.resolve(source: source, kind: kind, at: now) }
    }
    func dataInterruption(deadline: Date?) {
        guard let deadline else { resolve(source: "hiro", kind: "data-interrupted"); return }
        let now = Date()
        update { journal in
            guard !journal.entries.contains(where: {
                $0.source == "hiro" && $0.kind == "data-interrupted" && ($0.resolvedAt == nil || $0.issuedAt == deadline)
            }) else { return }
            journal.issue(.init(source: "hiro", kind: "data-interrupted",
                title: String(localized: "Glucose Data Interrupted"),
                body: String(localized: "No new glucose readings for 6 minutes. Open Trio and check the CGM connection."),
                issuedAt: deadline), now: now)
        }
    }
    @MainActor func importDeliveredWatchdog() async {
        for note in await UNUserNotificationCenter.current().deliveredNotifications()
            where note.request.identifier == "background-keep-alive-stall" {
            let seconds = note.request.content.userInfo["deadline"] as? TimeInterval
            dataInterruption(deadline: seconds.map(Date.init(timeIntervalSince1970:)) ?? note.date)
        }
    }
    private func update(_ change: @escaping (inout AlertJournal) -> Void) {
        repository.update(now: Date(), change)
        if repository.unavailable {
            DiagnosticEventStore.shared.record(feature: "privacy", stage: "journal", outcome: "failed")
        }
        notify()
    }
    private func notify() {
        DispatchQueue.main.async { Foundation.NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}

import Foundation
import PrivacyKit
import UserNotifications

/// Private on-device audit; never consumed by the active alarm replay or diagnostic ZIP.
final class HiroAlertJournal: @unchecked Sendable {
    static let shared = HiroAlertJournal()
    static let changed = Notification.Name("com.hiro.alertJournal.changed")
    private let lock = NSLock()
    private let url: URL
    private var journal: AlertJournal

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HiroExtensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("alert-journal.json")
        journal = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AlertJournal.self, from: $0) } ?? .init()
        journal.prune(now: Date())
        persist()
    }

    func recent() -> [JournalAlert] {
        lock.lock(); defer { lock.unlock() }
        return journal.recent(now: Date())
    }

    func issue(_ entry: JournalAlert) { update { $0.issue(entry, now: Date()) } }
    func acknowledge(source: String, kind: String) { update { $0.acknowledge(source: source, kind: kind, at: Date()) } }
    func resolve(source: String, kind: String) { update { $0.resolve(source: source, kind: kind, at: Date()) } }

    func dataInterruption(deadline: Date?) {
        guard let deadline else { resolve(source: "hiro", kind: "data-interrupted"); return }
        update { journal in
            guard !journal.entries.contains(where: {
                $0.source == "hiro" && $0.kind == "data-interrupted" && $0.issuedAt == deadline
            }) else { return }
            journal.issue(.init(source: "hiro", kind: "data-interrupted",
                title: String(localized: "Glucose Data Interrupted"),
                body: String(localized: "No new glucose readings for 6 minutes. Open Trio and check the CGM connection."),
                issuedAt: deadline), now: Date())
        }
    }

    /// The system can deliver the pre-scheduled watchdog while this process is suspended.
    /// Capture it before the coordinator clears a delivered request. Scheduling alone is not an issue.
    @MainActor func importDeliveredWatchdog() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        for note in delivered where note.request.identifier == "background-keep-alive-stall" {
            let deadline = note.request.content.userInfo["deadline"] as? TimeInterval
            dataInterruption(deadline: deadline.map(Date.init(timeIntervalSince1970:)) ?? note.date)
        }
    }

    private func update(_ change: (inout AlertJournal) -> Void) {
        lock.lock()
        let before = journal.entries
        change(&journal)
        journal.prune(now: Date())
        guard before != journal.entries else { lock.unlock(); return }
        persist()
        lock.unlock()
        DispatchQueue.main.async { Foundation.NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(journal) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var target = url; try target.setResourceValues(excluded)
        } catch {
            // No content or free-form errors enter the default export.
            Foundation.NotificationCenter.default.post(name: .init("com.trio.diagnostics.event"), object: nil,
                userInfo: ["schema": 1, "feature": "privacy", "stage": "journal", "outcome": "failed"])
        }
    }
}

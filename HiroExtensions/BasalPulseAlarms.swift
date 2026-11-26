import CryptoKit
import Foundation
import LoopKit
import MedtrumKit
import MedtrumLifecycleKit
import UIKit
#if canImport(AlarmKit)
    import AlarmKit
#endif

/// Alarm tickets and driver commands have separate durable ownership. No sound action unlocks delivery.
@MainActor final class HiroBasalPulseAlarms {
    static let shared = HiroBasalPulseAlarms()
    private typealias Ticket = MedtrumShortTempAlarmOwnership.Ticket
    private struct Saved: Codable {
        var ownership = MedtrumShortTempAlarmOwnership()
        var scopes: [UUID: String] = [:]
    }
    private static let storeKey = "hiro.shortTemp.protectedAlarms.v2"
    private var saved = Saved()
    private let readiness = MedtrumShortTempAlarmReadiness()
    private let scheduler = CriticalAlertAlarmScheduler()
    private weak var manager: MedtrumPumpManager?
    private var attachedIdentity: ObjectIdentifier?
    private var preparing = Set<UUID>()
    private var busy = Set<UUID>()
    private var inFlight = Set<UUID>()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var issue: ((Alert) -> Void)?
    private var retract: ((Alert.Identifier) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let restored = try? JSONDecoder().decode(Saved.self, from: data) { saved = restored }
        observer = Foundation.NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reconcile() } }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        #if canImport(AlarmKit)
            if #available(iOS 26, *) {
                Task { @MainActor [weak self] in
                    for await _ in AlarmManager.shared.authorizationUpdates { self?.refreshReadiness() }
                }
                Task { @MainActor [weak self] in
                    for await _ in AlarmManager.shared.alarmUpdates { self?.refreshReadiness() }
                }
            }
        #endif
    }

    private func persist() {
        let known = Set(saved.ownership.commandIDs)
        saved.scopes = saved.scopes.filter { known.contains($0.key) }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        refreshReadiness()
    }
    private static func scope(_ pump: MedtrumPumpManager) -> String {
        SHA256.hash(data: pump.shortTempAlarmScope).map { String(format: "%02x", $0) }.joined()
    }
    private static func identifier(command: UUID, ticket: UUID? = nil) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "Medtrum", alertIdentifier: "com.nightscout.medtrumkit.short-temp-cancel." +
            command.uuidString + (ticket.map { "." + $0.uuidString } ?? ".notice"))
    }
    private static func alert(command: UUID, ticket: UUID? = nil, audible: Bool = true, companion: Bool = false) -> Alert {
        let content = Alert.Content(title: String(localized: "Temporary delivery needs attention"),
            body: companion ? String(localized: "The pulse ended but its follow-up basal could not be confirmed. Open hiro and check the pump.") :
                String(localized: "Temporary basal cancellation has not been confirmed. Open hiro and check the pump connection and delivery status."),
            acknowledgeActionButtonLabel: String(localized: "View status"))
        return Alert(identifier: identifier(command: command, ticket: ticket), foregroundContent: content, backgroundContent: content,
            trigger: .immediate, interruptionLevel: .critical, sound: audible ? .sound(name: "honk.caf") : nil)
    }
    private func actualTickets(_ command: UUID, futureOnly: Bool) -> [Ticket] {
        saved.ownership.activeTickets(command).filter {
            (!futureOnly || $0.deadline > Date()) &&
                scheduler.containsShortTempAlarm(Self.identifier(command: command, ticket: $0.id))
        }
    }
    private func refreshReadiness() {
        var deadlines: [UUID: Date] = [:]
        if scheduler.isAuthorizedAndAvailable {
            for command in saved.ownership.commandIDs where !saved.ownership.isResolved(command) {
                let tickets = actualTickets(command, futureOnly: true)
                if tickets.count >= 2 { deadlines[command] = tickets.map(\.deadline).min() }
            }
        }
        readiness.replace(authorized: scheduler.isAuthorizedAndAvailable, deadlines: deadlines)
    }

    func attach(_ pump: MedtrumPumpManager, issueAlert: @escaping (Alert) -> Void,
                retractAlert: @escaping (Alert.Identifier) -> Void) {
        manager = pump
        attachedIdentity = ObjectIdentifier(pump)
        issue = issueAlert
        retract = retractAlert
        let identity = ObjectIdentifier(pump)
        let gate = readiness
        pump.shortTempBasalAlarmIsValid = { gate.permits($0) }
        pump.shortTempBasalAlarmDidEnterDriver = { [weak self] command in
            Task { @MainActor in self?.preparing.remove(command) }
        }
        pump.armShortTempBasalAlarm = { [weak self, weak pump] command, deadline, completion in
            Task { @MainActor in
                guard let self, let pump, self.manager === pump, self.attachedIdentity == identity else { completion(false); return }
                self.preparing.insert(command)
                self.saved.scopes[command] = Self.scope(pump)
                let accepted = await self.ensureGuards(command, firstDeadline: deadline)
                guard self.manager === pump, self.attachedIdentity == identity else {
                    self.resolve(command); completion(false); return
                }
                completion(accepted && self.readiness.permits(command))
            }
        }
        pump.retireShortTempBasalAlarm = { [weak self] command in Task { @MainActor in self?.resolve(command) } }
        pump.reportShortTempBasalFailure = { [weak self] command in
            Task { @MainActor in await self?.failure(command) }
        }
        pump.reportBasalPulseCompanionFailure = { [weak self] command in
            Task { @MainActor in await self?.failure(command, companion: true) }
        }
        reconcile()
    }

    private func remove(_ ticket: Ticket) {
        guard scheduler.cancelAlarm(for: Self.identifier(command: ticket.commandID, ticket: ticket.id)) else {
            saved.ownership.requestCleanup(ticket); persist(); return
        }
        saved.ownership.cancelled(ticket)
        persist()
    }
    private func schedule(_ command: UUID, at deadline: Date) async -> Ticket? {
        guard scheduler.isAuthorizedAndAvailable, deadline > Date(),
              let ticket = saved.ownership.reserve(commandID: command, deadline: deadline) else { return nil }
        inFlight.insert(ticket.id)
        persist()
        let accepted = await scheduler.prearmShortTemp(Self.alert(command: command, ticket: ticket.id), at: deadline)
        inFlight.remove(ticket.id)
        if accepted, saved.ownership.accept(ticket) {
            persist(); return ticket
        }
        // A late OS acceptance never resurrects a closed command. Cleanup is itself durable/retryable.
        if accepted { _ = saved.ownership.accept(ticket) }
        remove(ticket)
        return nil
    }

    private func ensureGuards(_ command: UUID, firstDeadline: Date) async -> Bool {
        guard !saved.ownership.isResolved(command), !busy.contains(command), scheduler.isAuthorizedAndAvailable else { return false }
        busy.insert(command)
        defer { busy.remove(command) }
        let boundary = max(max(firstDeadline, saved.ownership.nextWarningNotBefore(command) ?? firstDeadline), Date().addingTimeInterval(2))
        var future = actualTickets(command, futureOnly: true).filter { $0.deadline >= boundary.addingTimeInterval(-2) }
        if future.isEmpty {
            guard let first = await schedule(command, at: boundary) else { return false }
            future = [first]
            // The new alarm is accepted before any older one is removed.
            for older in actualTickets(command, futureOnly: true) where older.id != first.id && older.deadline < boundary {
                remove(older)
            }
        }
        if future.count < 2 {
            let backupAt = max(boundary, future.map(\.deadline).max() ?? boundary).addingTimeInterval(60)
            guard await schedule(command, at: backupAt) != nil else { return false }
        }
        refreshReadiness()
        return readiness.permits(command)
    }

    private func resolve(_ command: UUID) {
        preparing.remove(command)
        let tickets = saved.ownership.resolve(command)
        persist() // Tombstone before cancellation or any await callback can arrive.
        for ticket in tickets { remove(ticket) }
        retract?(Self.identifier(command: command))
        if manager?.shortTempAlarmRequests.isEmpty == true {
            for suffix in ["", ".companion"] {
                retract?(Alert.Identifier(managerIdentifier: "Medtrum", alertIdentifier: "com.nightscout.medtrumkit.short-temp-cancel" + suffix))
            }
        }
    }
    private func failure(_ command: UUID, companion: Bool = false) async {
        guard !saved.ownership.isResolved(command) else { return }
        if let pump = manager, saved.scopes[command] == nil { saved.scopes[command] = Self.scope(pump) }
        let urgentAt = max(Date().addingTimeInterval(2), saved.ownership.nextWarningNotBefore(command) ?? .distantPast)
        let urgent = await schedule(command, at: urgentAt)
        if let urgent {
            let backups = actualTickets(command, futureOnly: true).filter { $0.id != urgent.id && $0.deadline >= Date().addingTimeInterval(45) }
            if !backups.isEmpty {
                for old in actualTickets(command, futureOnly: true) where old.id != urgent.id && !backups.contains(where: { $0.id == old.id }) { remove(old) }
            }
        }
        _ = await ensureGuards(command, firstDeadline: Date().addingTimeInterval(2))
        guard !saved.ownership.isResolved(command) else { return }
        let systemHasAudio = !actualTickets(command, futureOnly: false).isEmpty
        issue?(Self.alert(command: command, audible: !systemHasAudio, companion: companion))
    }

    private func reconcile() {
        for ticket in saved.ownership.cleanupTickets where !inFlight.contains(ticket.id) { remove(ticket) }
        for command in saved.ownership.commandIDs {
            for ticket in saved.ownership.activeTickets(command) where !inFlight.contains(ticket.id) &&
                !scheduler.containsShortTempAlarm(Self.identifier(command: command, ticket: ticket.id)) { remove(ticket) }
        }
        guard let pump = manager else { return }
        let scope = Self.scope(pump)
        let requests = pump.shortTempAlarmRequests
        for command in saved.ownership.commandIDs where !saved.ownership.isResolved(command) && saved.scopes[command] == scope {
            if !preparing.contains(command), !requests.contains(where: { $0.commandID == command }), pump.canRetireOrphanShortAlarm(command) {
                resolve(command)
            }
        }
        for request in requests {
            guard !busy.contains(request.commandID), !saved.ownership.isResolved(request.commandID) else { continue }
            saved.scopes[request.commandID] = scope
            if actualTickets(request.commandID, futureOnly: true).count < 2 {
                Task { @MainActor in _ = await ensureGuards(request.commandID, firstDeadline: request.deadline) }
            }
        }
        refreshReadiness()
    }

    /// The system already stopped this ticket. Keep other accepted tickets while adding its successor.
    func stopped(_ identifier: Alert.Identifier) async -> Bool {
        let owner = saved.ownership.commandIDs.first { command in
            Self.identifier(command: command) == identifier || saved.ownership.activeTickets(command).contains {
                Self.identifier(command: command, ticket: $0.id) == identifier
            }
        }
        guard let command = owner else { return false }
        guard !saved.ownership.isResolved(command) else { return true }
        saved.ownership.recordStop(command, until: Date().addingTimeInterval(60))
        persist()
        _ = await ensureGuards(command, firstDeadline: Date().addingTimeInterval(60))
        return true
    }
}

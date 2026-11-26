import LoopKit
import MedtrumKit
import Foundation
import UIKit

extension DosingMode {
    func effectiveForPump(_ pump: PumpManager?) -> Self {
        let restricted = (pump as? MedtrumPumpManager)?.automaticBolusContext().restrictionReason == "basal_only"
        return effectiveForDevice(basalOnly: restricted)
    }
}

/// System alarm ownership is keyed to the persisted short-temp command, not a global snooze tier.
@MainActor final class HiroBasalPulseAlarms {
    static let shared = HiroBasalPulseAlarms()
    private struct Pending: Codable {
        let commandID: UUID
        var deadline: Date
    }
    private static let storeKey = "hiro.shortTemp.protectedAlarms.v1"
    private var pending: [UUID: Pending] = [:]
    private let scheduler = CriticalAlertAlarmScheduler()
    private weak var manager: MedtrumPumpManager?
    private var attachedIdentity: ObjectIdentifier?
    private var recoveryInFlight = Set<UUID>()
    private var observer: NSObjectProtocol?
    private var retractLegacyAlerts: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([Pending].self, from: data) {
            pending = Dictionary(saved.map { ($0.commandID, $0) }, uniquingKeysWith: { a, _ in a })
        }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reconcile() } }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(pending.values)) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private static func identifier(_ id: UUID) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "Medtrum",
            alertIdentifier: "com.nightscout.medtrumkit.short-temp-cancel." + id.uuidString)
    }

    private static func alert(_ id: UUID) -> Alert {
        let content = Alert.Content(title: String(localized: "Temporary delivery stop not confirmed"),
            body: String(localized: "Temporary basal cancellation has not been confirmed. Open hiro and check the pump connection and delivery status."),
            acknowledgeActionButtonLabel: String(localized: "View status"))
        return Alert(identifier: identifier(id), foregroundContent: content, backgroundContent: content,
            trigger: .immediate, interruptionLevel: .critical, sound: .sound(name: "honk.caf"))
    }

    func attach(_ pump: MedtrumPumpManager, retractLegacyAlerts: @escaping () -> Void) {
        manager = pump
        self.retractLegacyAlerts = retractLegacyAlerts
        attachedIdentity = ObjectIdentifier(pump)
        let identity = ObjectIdentifier(pump)
        pump.armShortTempBasalAlarm = { [weak self, weak pump] id, deadline, completion in
            Task { @MainActor in
                guard let self, let pump, self.attachedIdentity == identity, self.manager === pump else {
                    completion(false); return
                }
                let accepted = await self.arm(id, deadline: deadline)
                guard self.attachedIdentity == identity, self.manager === pump else {
                    self.retire(id); completion(false); return
                }
                completion(accepted)
            }
        }
        pump.retireShortTempBasalAlarm = { [weak self] id in
            Task { @MainActor in self?.retire(id) }
        }
        reconcile()
    }

    private func arm(_ id: UUID, deadline: Date) async -> Bool {
        guard scheduler.isAuthorizedAndAvailable, deadline > Date() else { return false }
        // Keep an earlier already-armed warning rather than cancel/recreate the only protection.
        if let existing = pending[id], existing.deadline <= deadline,
           scheduler.containsShortTempAlarm(Self.identifier(id)) { return true }
        pending[id] = Pending(commandID: id, deadline: deadline)
        save()
        let accepted = await scheduler.prearmShortTemp(Self.alert(id), at: deadline)
        if !accepted { pending.removeValue(forKey: id); save() }
        return accepted
    }

    private func retire(_ id: UUID) {
        pending.removeValue(forKey: id)
        save()
        scheduler.cancelAlarm(for: Self.identifier(id))
        if manager?.shortTempAlarmRequests.isEmpty == true {
            retractLegacyAlerts?()
        }
    }

    private func reconcile() {
        guard let manager else { return }
        for request in manager.shortTempAlarmRequests {
            guard !scheduler.containsShortTempAlarm(Self.identifier(request.commandID)),
                  !recoveryInFlight.contains(request.commandID) else { continue }
            recoveryInFlight.insert(request.commandID)
            Task { @MainActor in
                _ = await arm(request.commandID, deadline: max(request.deadline, Date().addingTimeInterval(2)))
                recoveryInFlight.remove(request.commandID)
            }
        }
    }

    /// The Stop intent may be launched in a fresh process; the pending registry survives it.
    func stopped(_ identifier: Alert.Identifier) async -> Bool {
        guard let record = pending.values.first(where: { Self.identifier($0.commandID) == identifier }) else { return false }
        let next = Date().addingTimeInterval(60)
        pending[record.commandID] = Pending(commandID: record.commandID, deadline: next)
        save()
        scheduler.cancelAlarm(for: identifier)
        let accepted = await scheduler.prearmShortTemp(Self.alert(record.commandID), at: next)
        if !accepted {
            // Persist unresolved ownership; never clear the pump's guards on a sound failure.
            DiagnosticEventStore.shared.record(feature: "alerts", stage: "alarm", outcome: "failed")
        }
        return true
    }
}

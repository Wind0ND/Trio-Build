import Combine
import Foundation
import LoopKit

/// Separate reminder bookkeeping; never changes APS's actual successful-loop date.
final class HiroLoopReminderWindow {
    private struct State: Codable {
        var manualActive = false
        var resumeAnchor: Date?
    }

    private let key = "hiro.loopTimeoutRecoveryWindow.v1"
    private let defaults: UserDefaults?
    private var state = State()
    var manualActive: Bool { state.manualActive }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: key), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    @discardableResult func setManualTempBasal(_ active: Bool, at date: Date) -> Bool {
        guard active != state.manualActive, date.timeIntervalSince1970.isFinite else { return false }
        state.manualActive = active
        if !active { state.resumeAnchor = date }
        save()
        return true
    }

    func beginRecovery(at date: Date) {
        guard !manualActive, date.timeIntervalSince1970.isFinite else { return }
        state.resumeAnchor = date
        save()
    }

    func anchor(lastSuccess: Date) -> Date { max(lastSuccess, state.resumeAnchor ?? .distantPast) }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults?.set(data, forKey: key) }
    }
}

/// Independent preference for the loop watchdog; other alarms keep their existing settings.
final class HiroLoopReminderPreferences: ObservableObject {
    static let shared = HiroLoopReminderPreferences()
    @Published var enabled: Bool
    private var subscription: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        let key = "hiro.loopTimeoutRemindersEnabled"
        enabled = defaults.object(forKey: key) as? Bool ?? true
        subscription = $enabled.dropFirst().removeDuplicates().sink { defaults.set($0, forKey: key) }
    }

    func allows(_ identifier: Alert.Identifier) -> Bool {
        enabled || AlertCatalogRegistry.lookup(identifier)?.concept != .notLooping
    }
}

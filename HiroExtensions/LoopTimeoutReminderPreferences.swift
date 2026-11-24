import Combine
import Foundation
import LoopKit

/// Separate reminder bookkeeping; never changes APS's actual successful-loop date.
final class HiroLoopReminderWindow {
    private(set) var manualActive = false
    init(defaults: UserDefaults? = nil) {}
    @discardableResult func setManualTempBasal(_ active: Bool, at date: Date) -> Bool { false }
    func anchor(lastSuccess: Date) -> Date { lastSuccess }
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

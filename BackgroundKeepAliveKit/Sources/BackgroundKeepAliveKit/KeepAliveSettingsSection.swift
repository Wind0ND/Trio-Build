#if os(iOS)
import SwiftUI

public struct KeepAliveSettingsSection: View {
    @ObservedObject private var monitor = BackgroundKeepAlive.shared
    @AppStorage(BackgroundKeepAlive.SettingsKey.mode) private var mode = KeepAliveMode.smart.rawValue
    @AppStorage(BackgroundKeepAlive.SettingsKey.stallMinutes) private var stall = 10
    @AppStorage(BackgroundKeepAlive.SettingsKey.maxSessionMinutes) private var cap = 45

    public init() {}

    public var body: some View {
        Section {
            Picker(text("Protection mode"), selection: $mode) {
                Text(text("Off")).tag(KeepAliveMode.off.rawValue)
                Text(text("Automatic protection")).tag(KeepAliveMode.smart.rawValue)
                Text(text("Continuous audio fallback")).tag(KeepAliveMode.always.rawValue)
            }
            if mode != KeepAliveMode.off.rawValue {
                Stepper(value: $stall, in: 5 ... 60, step: 5) {
                    Text("Interruption threshold: \(stall) minutes", bundle: .module)
                }
                if mode == KeepAliveMode.smart.rawValue {
                    Stepper(value: $cap, in: 15 ... 180, step: 15) {
                        Text("Recovery audio limit: \(cap) minutes", bundle: .module)
                    }
                }
                LabeledContent(text("Current protection"), value: statusText)
                Text(text("Automatic protection starts when the app enters the background, before readings become overdue. Bluetooth events drive recovery; audio is an optional fallback and may be interrupted by video or calls. It can increase battery use. iOS controls background execution."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text(text("Background protection")) }
        .onChange(of: mode) { _, _ in monitor.settingsChanged() }
        .onChange(of: stall) { _, _ in monitor.settingsChanged() }
        .onChange(of: cap) { _, _ in monitor.settingsChanged() }
    }

    private func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "Background protection settings")
    }

    private var statusText: String {
        switch monitor.status {
        case .disabled: return text("Disabled")
        case .noSource: return text("No active source")
        case .foreground: return text("App in foreground")
        case .protecting: return text("Audio fallback running")
        case .interrupted: return text("Audio interrupted; awaiting a wake opportunity")
        case .alert: return text("Alarm has audio priority")
        case .limited: return text("Audio recovery limit reached")
        case .failed: return text("Audio unavailable; Bluetooth recovery remains enabled")
        }
    }
}
#endif

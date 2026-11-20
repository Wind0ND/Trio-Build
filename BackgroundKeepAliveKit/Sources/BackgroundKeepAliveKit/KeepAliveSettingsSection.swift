#if os(iOS)
import SwiftUI

public struct KeepAliveSettingsSection: View {
    @ObservedObject private var monitor = BackgroundKeepAlive.shared
    @AppStorage(BackgroundKeepAlive.SettingsKey.mode) private var mode = KeepAliveMode.smart.rawValue
    @AppStorage(BackgroundKeepAlive.SettingsKey.cycleMinutes) private var cycle = 30
    @AppStorage(BackgroundKeepAlive.SettingsKey.audioMinutes) private var duration = 5

    public init() {}

    public var body: some View {
        Section {
            Picker(text("Protection mode"), selection: $mode) {
                Text(text("Off")).tag(KeepAliveMode.off.rawValue)
                Text(text("Automatic protection")).tag(KeepAliveMode.smart.rawValue)
                Text(text("Continuous audio fallback")).tag(KeepAliveMode.always.rawValue)
                Text(text("Periodic audio (experimental)")).tag(KeepAliveMode.periodic.rawValue)
            }
            if mode != KeepAliveMode.off.rawValue {
                if mode == KeepAliveMode.periodic.rawValue {
                    Stepper(value: $cycle, in: 5 ... 240, step: 5) {
                        Text("Audio cycle: \(cycle) minutes", bundle: .module)
                    }
                    Stepper(value: $duration, in: 1 ... max(1, cycle - 1)) {
                        Text("Audio per cycle: \(duration) minutes", bundle: .module)
                    }
                }
                LabeledContent(text("Current protection"), value: statusText)
                LabeledContent(text("Audio session time this launch"), value: Duration.seconds(monitor.audioSessionSeconds).formatted(.time(pattern: .hourMinuteSecond)))
                LabeledContent(text("Audio starts this launch"), value: "\(monitor.audioStarts)")
                if mode == KeepAliveMode.periodic.rawValue {
                    LabeledContent(text("Last audio window delay"), value: Duration.seconds(monitor.lastCycleDelaySeconds).formatted(.time(pattern: .minuteSecond)))
                }
                Text(text("Automatic mode keeps audio off while readings update. After six minutes without a valid update, it attempts audio until valid updates resume. Continuous mode attempts audio throughout the background session. Periodic mode follows adjustable on/off windows; iOS suspension can delay or skip them. Session time is an estimate, not a battery measurement."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text(text("Background protection")) }
        .onChange(of: mode) { _, _ in monitor.settingsChanged() }
        .onChange(of: cycle) { _, value in
            duration = min(max(1, duration), value - 1)
            monitor.settingsChanged()
        }
        .onChange(of: duration) { _, _ in monitor.settingsChanged() }
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
        case .waiting: return text("Audio off; waiting for data or the next audio window")
        }
    }
}
#endif

import BackgroundKeepAliveKit
import PrivacyAppKit
import SwiftUI
import Swinject

/// Custom settings stay together; device setup and the upstream settings retain their own routes.
struct HiroExtensionsSettingsView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section {
                Text("Privacy").navigationLink(to: .privacySettings, from: self)
                Text("Background protection").navigationLink(to: .backgroundProtection, from: self)
                Text("Alert History (24 Hours)").navigationLink(to: .alertJournal, from: self)
                Text("App Icons").navigationLink(to: .iconConfig, from: self)
            }
            Section {
                Text("Device Lifetime Extensions").navigationLink(to: .deviceLifetimeExtensions, from: self)
            }
            Section {
                LogShareRow(
                    title: "Export Diagnostics",
                    footnote: "Includes app version and feature events for scanning, pairing and background monitoring.",
                    kinds: [.diagnostics], logExport: state.logExport
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Extensions")
        .onAppear { configureView() }
    }
}

struct HiroBackgroundProtectionView: View {
    var body: some View {
        Form { KeepAliveSettingsSection() }
            .navigationTitle("Background protection")
    }
}

struct HiroDeviceLifetimeView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel
    @AppStorage("ottaiExtraWearDays") private var ottaiExtraWearDays = 0

    var body: some View {
        Form {
            Section("CGM Wear Duration") {
                Stepper(
                    ottaiExtraWearDays == 0 ? "Ottai wear extension: off" : "Ottai wear extension: +\(ottaiExtraWearDays) days",
                    value: $ottaiExtraWearDays, in: 0 ... 28, step: 7
                )
                Text("Only changes the expiry check in Trio. It does not change the server's rated wear duration or the sensor firmware. The official app still uses its own expiration date.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("Insulin Pump").navigationLink(to: .pumpConfig, from: self)
                Text("Patch duration options remain in the connected pump's settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Device Lifetime Extensions")
        .onAppear { configureView() }
    }
}

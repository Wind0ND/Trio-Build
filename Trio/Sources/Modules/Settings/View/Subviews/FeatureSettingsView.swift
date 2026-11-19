//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import BackgroundKeepAliveKit
import PrivacyAppKit
import Foundation
import SwiftUI
import Swinject

struct FeatureSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @AppStorage(BackgroundKeepAlive.SettingsKey.mode) private var keepAliveMode: String = KeepAliveMode.smart.rawValue
    @AppStorage(BackgroundKeepAlive.SettingsKey.stallMinutes) private var stallMinutes: Int = 10
    @AppStorage(BackgroundKeepAlive.SettingsKey.maxSessionMinutes) private var maxSessionMinutes: Int = 45
    @AppStorage("ottaiExtraWearDays") private var ottaiExtraWearDays: Int = 0

    var body: some View {
        Form {
            Section(
                header: Text("Trio Features"),
                content: {
                    Text("Treatments").navigationLink(to: .treatmentsSettings, from: self)
                    Text("Shortcuts").navigationLink(to: .shortcutsConfig, from: self)
                    Text("Remote Control").navigationLink(to: .remoteControlConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Trio Personalization"),
                content: {
                    NavigationLink(destination: PrivacySettingsView()) {
                        Label(String(localized: "Privacy"), systemImage: "eye.slash")
                    }
                    Text("User Interface").navigationLink(to: .userInterfaceSettings, from: self)
                    Text("App Icons").navigationLink(to: .iconConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Background Keep Alive"),
                content: {
                    Picker("Keep Alive Mode", selection: $keepAliveMode) {
                        ForEach(KeepAliveMode.allCases) { mode in
                            Text(modeTitle(mode)).tag(mode.rawValue)
                        }
                    }
                    if keepAliveMode == KeepAliveMode.smart.rawValue {
                        Stepper(
                            "Glucose interruption threshold: \(stallMinutes) minutes",
                            value: $stallMinutes,
                            in: 5 ... 60,
                            step: 5
                        )
                        Stepper(
                            "Maximum keep alive: \(maxSessionMinutes) minutes",
                            value: $maxSessionMinutes,
                            in: 15 ... 180,
                            step: 15
                        )
                    }
                    Text("Trio schedules a glucose interruption reminder. In Smart mode, audio can start if Trio is running when readings become overdue. Always uses background audio and can increase battery use.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            )
            .listRowBackground(Color.chart)
            Section(
                header: Text("CGM Wear Duration"),
                content: {
                    Stepper(
                        ottaiExtraWearDays == 0
                            ? "Ottai wear extension: off"
                            : "Ottai wear extension: +\(ottaiExtraWearDays) days",
                        value: $ottaiExtraWearDays,
                        in: 0 ... 28,
                        step: 7
                    )
                    Text("Only changes the expiry check in Trio. It does not change the server's rated wear duration or the sensor firmware. The official app still uses its own expiration date.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            )
            .listRowBackground(Color.chart)
            Section(
                header: Text("Anonymized Data Sharing"),
                content: {
                    Text("App Diagnostics").navigationLink(to: .appDiagnostics, from: self)
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Feature Settings")
        .navigationBarTitleDisplayMode(.automatic)
        .onChange(of: keepAliveMode) { _, _ in BackgroundKeepAlive.shared.settingsChanged() }
        .onChange(of: stallMinutes) { _, _ in BackgroundKeepAlive.shared.settingsChanged() }
        .onChange(of: maxSessionMinutes) { _, _ in BackgroundKeepAlive.shared.settingsChanged() }
    }

    private func modeTitle(_ mode: KeepAliveMode) -> LocalizedStringKey {
        switch mode {
        case .off: "Off"
        case .smart: "Smart (keep alive only when readings stop)"
        case .always: "Always (keep alive in the background)"
        }
    }
}

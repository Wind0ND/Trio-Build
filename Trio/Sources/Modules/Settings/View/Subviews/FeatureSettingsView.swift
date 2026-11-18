//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import SwiftUI
import Swinject

struct FeatureSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @AppStorage("backgroundKeepAlive.mode") private var keepAliveMode: String = BackgroundKeepAlive.Mode.smart.rawValue
    @AppStorage("backgroundKeepAlive.stallMinutes") private var stallMinutes: Int = 10
    @AppStorage("backgroundKeepAlive.maxSessionMinutes") private var maxSessionMinutes: Int = 45
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
                    Text("User Interface").navigationLink(to: .userInterfaceSettings, from: self)
                    Text("App Icons").navigationLink(to: .iconConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Background Keep Alive"),
                content: {
                    Picker("Keep Alive Mode", selection: $keepAliveMode) {
                        ForEach(BackgroundKeepAlive.Mode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    if keepAliveMode == BackgroundKeepAlive.Mode.smart.rawValue {
                        Stepper(
                            "Start keep alive after \(stallMinutes) minutes without readings",
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
                    Text("Keep Trio running in the background so it can reconnect more quickly after CGM disconnects. Smart mode only starts when readings stop and can use more battery.")
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
    }
}

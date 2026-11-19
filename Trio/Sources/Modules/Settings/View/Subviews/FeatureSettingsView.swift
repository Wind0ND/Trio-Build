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

            KeepAliveSettingsSection()
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

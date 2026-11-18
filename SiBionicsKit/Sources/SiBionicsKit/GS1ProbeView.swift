#if os(iOS)
import CGMSetupKit
import SwiftUI

@MainActor
public struct GS1ProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var probe = GS1Probe()
    @State private var identifier = ""

    public init() {}

    public static var title: String { String(localized: "Sibionics GS1 Connection Test", bundle: .module) }

    public var body: some View {
        List {
            Section {
                Text("Use a spare or test sensor. This check connects briefly and looks for the GS1 Bluetooth service.", bundle: .module)
                Text("If another app is connected to the test sensor, close that app from the app switcher before starting.", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if !probe.isActive {
                    CGMCodeInput(normalize: CGMPackageCode.sibionicsIdentifier) { identifier = $0 }
                }
                TextField(text: $identifier) {
                    Text("Connection Code or Serial", bundle: .module)
                }
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .disabled(probe.isActive)

                if probe.isActive {
                    Button(String(localized: "Stop Test", bundle: .module), action: probe.stop)
                } else {
                    Button(String(localized: "Test Bluetooth Connection", bundle: .module)) {
                        if let target = GS1Target(input: identifier) { probe.start(target) }
                    }
                    .disabled(GS1Target(input: identifier) == nil)
                }
            }

            Section {
                if probe.isActive {
                    HStack {
                        ProgressView()
                        Text(status, bundle: .module)
                    }
                } else {
                    Text(status, bundle: .module)
                }
            } header: {
                Text("Connection Status", bundle: .module)
            } footer: {
                Text("The diagnostics export records connection stages and outcomes. This test ends before glucose retrieval.", bundle: .module)
            }
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { probe.stop() }
        }
        .onDisappear { probe.stop() }
    }

    private var status: LocalizedStringKey {
        switch probe.phase {
        case .idle: "Scan the package code or enter the code printed on the box."
        case .searching: "Searching nearby for this sensor…"
        case .connecting: "Sensor matched. Connecting…"
        case .inspecting: "Connected. Checking Bluetooth services…"
        case .ready: "Found Bluetooth service FF30 and characteristic FF31. Device model is unverified."
        case .unavailable: "Bluetooth unavailable. Check Bluetooth and Trio’s permissions."
        case .notFound: "No exact Bluetooth name matched. Check the complete name and keep the sensor nearby."
        case .failed: "Connection or service check failed. Export diagnostics for details."
        case .stopped: "Test stopped."
        }
    }
}
#endif

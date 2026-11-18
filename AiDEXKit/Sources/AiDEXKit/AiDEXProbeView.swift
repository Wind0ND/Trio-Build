#if os(iOS)
import CGMSetupKit
import Combine
import Foundation
import SwiftUI

private func localized(_ key: String) -> String {
    AiDEXLocalization.string(key)
}

public struct AiDEXProbeLinkRow: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: localized("AiDEX Foreground Probe"))
                .foregroundColor(.primary)
            Text(verbatim: localized(
                "Display-only test. Reads advertisements in the foreground and never replaces your CGM."
            ))
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

public struct AiDEXProbeView: View {
    @StateObject private var model = AiDEXProbeViewModel()
    @State private var serial = ""
    @Environment(\.scenePhase) private var scenePhase

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(localized("Testing only"), systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text(verbatim: localized(
                        "This screen does not activate, connect to, write to, or calibrate the sensor. It only listens for advertisements in the foreground. Activate the sensor with the official AiDEX app first, and keep your current CGM active."
                    ))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            Section {
                if !model.isActive {
                    CGMCodeInput(normalize: CGMPackageCode.aiDEXSerial) { serial = $0 }
                }
                TextField(text: $serial) {
                    Text(verbatim: localized("Sensor serial"))
                }
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .disabled(model.isActive)

                Text(verbatim: localized(
                    "Scan the box code or enter the sensor serial. Check the serial before starting the search."
                ))
                .font(.footnote)
                .foregroundColor(.secondary)

                if model.showsInvalidSerial {
                    Text(verbatim: localized("Enter a valid sensor serial."))
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                Button {
                    if model.isActive {
                        model.stop(.user)
                    } else {
                        model.start(serial: serial)
                    }
                } label: {
                    Label(
                        model.isActive ? localized("Stop Scan") : localized("Start Foreground Scan"),
                        systemImage: model.isActive ? "stop.circle" : "dot.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.isActive && serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(verbatim: localized("Sensor serial"))
            }

            Section {
                if let latest = model.latest {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(latest.glucoseMgdL)")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                        Text(verbatim: "mg/dL")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        if latest.isStale(at: model.now) {
                            Text(verbatim: localized("Stale — no new value"))
                                .font(.caption.bold())
                                .foregroundColor(.orange)
                        }
                    }
                    Text(verbatim: String(format: "%.1f mmol/L", latest.glucoseMmolL))
                        .font(.title3.monospacedDigit())
                    HStack {
                        Text(verbatim: localized("Received"))
                            .foregroundColor(.secondary)
                        Text(latest.receivedAt, format: .dateTime.hour().minute().second())
                    }
                    .font(.footnote)
                } else {
                    Text(verbatim: localized("No reading received yet."))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(verbatim: localized("Last reading"))
            }

            Section {
                Label(statusTitle, systemImage: statusIcon)
                    .font(.headline)
                Text(verbatim: statusDetail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(verbatim: localized("Status"))
            }

            Section {
                Text(verbatim: localized(
                    "Readings stay in memory only and are not used for dosing, alerts, or loop input."
                ))
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle(Text(verbatim: localized("AiDEX Foreground Probe")))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(ticker) { _ in
            model.tick()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.stop(.sceneInactive)
            }
        }
        .onChange(of: model.phase) { _, newPhase in
            switch newPhase {
            case .stopped, .unavailable:
                serial = ""
            default:
                break
            }
        }
        .onDisappear {
            serial = ""
            model.stop(.viewClosed)
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .idle:
            return localized("Idle")
        case .scanning:
            return localized("Scanning")
        case .matched:
            return localized("Sensor matched")
        case .stopped:
            return localized("Stopped")
        case let .unavailable(reason):
            switch reason {
            case .poweredOff:
                return localized("Bluetooth off")
            case .unauthorized:
                return localized("Bluetooth permission denied")
            case .unsupported, .notReady:
                return localized("Bluetooth unavailable")
            }
        }
    }

    private var statusDetail: String {
        switch model.phase {
        case .idle:
            return localized("Enter the sensor serial from the box, then start a foreground scan.")
        case .scanning:
            return localized("Searching nearby for the sensor with this serial.")
        case .matched:
            guard let latest = model.latest else {
                return localized("Sensor matched. Waiting for a valid advertisement.")
            }
            if latest.isStale(at: model.now) {
                return localized("Sensor matched. The last reading is stale; waiting for a new one.")
            }
            return localized("Sensor matched. Latest accepted reading is shown below.")
        case let .stopped(reason):
            switch reason {
            case .user:
                return localized("Scan stopped. Session data cleared.")
            case .sceneInactive:
                return localized("Trio left the foreground, so the scan stopped.")
            case .viewClosed:
                return localized("The probe screen closed, so the scan stopped.")
            case .disappeared:
                return localized("No advertisement from the sensor for 60 seconds, so the scan stopped.")
            }
        case let .unavailable(reason):
            switch reason {
            case .poweredOff:
                return localized("Bluetooth is off.")
            case .unauthorized:
                return localized("Bluetooth permission was denied.")
            case .unsupported:
                return localized("This iPhone does not support Bluetooth.")
            case .notReady:
                return localized("Bluetooth is not ready.")
            }
        }
    }

    private var statusIcon: String {
        switch model.phase {
        case .idle:
            return "circle.dashed"
        case .scanning:
            return "dot.radiowaves.left.and.right"
        case .matched:
            return "checkmark.circle"
        case .stopped:
            return "stop.circle"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }
}
#endif

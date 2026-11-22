#if canImport(UIKit)
import PhotosUI
import PrivacyKit
import SwiftUI
import UIKit

public struct PrivacySettingsView: View {
    @ObservedObject private var lock = PrivacyLockController.shared
    @AppStorage(PrivacyPreference.displayKey) private var privateDisplay = false
    @AppStorage(PrivacyPreference.alertsKey) private var privateAlerts = false
    @AppStorage(PrivacyPreference.biometricsKey) private var biometrics = false
    @AppStorage(PrivacyPreference.patternTraceKey) private var patternTrace = false
    @AppStorage(PrivacyPreference.paletteKey) private var palette = PrivacyPalettePreset.quiet.rawValue
    @AppStorage(PrivacyPreference.meterStyleKey) private var meterStyle = PrivacyMeterStyle.history.rawValue
    @State private var showSetup = false
    @State private var method: PrivacyLockMethod = .pin
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var coverSelectionGeneration = UUID()
    @State private var loadingCover = false
    @State private var cover = UserDefaults.standard.data(forKey: PrivacyPreference.coverKey)
    @State private var boundaryText = PrivacyPalette.stored().boundaries.map { String(format: "%.1f", $0) }
    @State private var message: String?

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle(privacyText("Private Live Activity"), isOn: protected($privateDisplay))
                Toggle(privacyText("Private alert wording"), isOn: protected($privateAlerts))
                Text(privacyText("Private activities show a cover and six small bars. Public glucose alerts say Attention. The existing alert sounds and schedules still apply."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(privacyText("System alarms already ringing keep their original title until stopped. Enable alert privacy before an alarm starts."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(privacyText("Cover")) {
                HStack {
                    PrivacyCoverView(data: cover, size: 36)
                    PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .compatible) {
                        Text(privacyText("Choose from Photos"))
                    }
                }
                if loadingCover { ProgressView(privacyText("Loading cover…")) }
                if cover != nil {
                    Button(privacyText("Use abstract cover")) {
                        lock.requireAuthentication {
                            coverSelectionGeneration = UUID()
                            selectedPhoto = nil
                            loadingCover = false
                            UserDefaults.standard.removeObject(forKey: PrivacyPreference.coverKey)
                            cover = nil
                            PrivacyPreference.record(stage: "cover", outcome: "reset")
                            PrivacyPreference.notifyChanged()
                        }
                    }
                }
            }
            Section(privacyText("Display appearance")) {
                Picker(privacyText("Color palette"), selection: protectedChoice($palette)) {
                    Text(privacyText("Quiet dark")).tag(PrivacyPalettePreset.quiet.rawValue)
                    Text(privacyText("Soft balanced")).tag(PrivacyPalettePreset.balanced.rawValue)
                    Text(privacyText("Muted mist")).tag(PrivacyPalettePreset.mist.rawValue)
                    Text(privacyText("Teal and gold")).tag(PrivacyPalettePreset.separated.rawValue)
                    Text(privacyText("Green and muted gold")).tag(PrivacyPalettePreset.gold.rawValue)
                    Text(privacyText("Soft light")).tag(PrivacyPalettePreset.soft.rawValue)
                }
                HStack {
                    ForEach(0 ..< 6, id: \.self) { index in
                        Circle().fill(selectedColors[index].swiftUIColor).frame(width: 18, height: 18)
                    }
                }.accessibilityHidden(true)
                Picker(privacyText("Waveform style"), selection: protectedChoice($meterStyle)) {
                    Text(privacyText("Six recent readings")).tag(PrivacyMeterStyle.history.rawValue)
                    Text(privacyText("Five readings and reference")).tag(PrivacyMeterStyle.referenceFive.rawValue)
                }
                Text(privacyText("The reference style shows the latest five readings, followed by a fixed 5 mmol/L marker at 41.7% height. The entire group, including the marker, uses the latest reading's color."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(privacyText("Color ranges")) {
                ForEach(0 ..< 5, id: \.self) { index in
                    HStack {
                        Circle().fill(selectedColors[index].swiftUIColor).frame(width: 12, height: 12)
                        Text(privacyText("Upper boundary"))
                        TextField("mmol/L", text: $boundaryText[index]).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text(verbatim: "mmol/L").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Circle().fill(selectedColors[5].swiftUIColor).frame(width: 12, height: 12)
                    Text(privacyText("Red represents values above the final boundary."))
                }
                Button(privacyText("Save color ranges"), action: saveBoundaries)
                Text(privacyText("Display ranges are independent of alarm thresholds. Bar heights use a fixed 0–12 mmol/L scale. Missing readings leave an empty slot. After six minutes without a new reading, a ring keeps the last color."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(privacyText("Viewing lock")) {
                Picker(privacyText("Unlock method"), selection: $method) {
                    Text(privacyText("4-digit PIN")).tag(PrivacyLockMethod.pin)
                    Text(privacyText("Pattern")).tag(PrivacyLockMethod.pattern)
                }
                Toggle(privacyText("Show pattern trace"), isOn: protected($patternTrace))
                Text(privacyText("When off, pattern input shows neither the path nor selected dots."))
                    .font(.footnote).foregroundStyle(.secondary)
                if lock.configured {
                    Button(privacyText("Change PIN or pattern")) { lock.requireAuthentication { showSetup = true } }
                    Toggle(privacyText("Allow Face ID or Touch ID"), isOn: protected($biometrics))
                    Button(privacyText("Lock now")) { lock.lockNow() }
                    Button(privacyText("Turn off viewing lock"), role: .destructive) {
                        lock.requireAuthentication { lock.disable() }
                    }
                } else {
                    Button(privacyText("Set up viewing lock")) { showSetup = true }
                }
                Text(privacyText("The viewing lock covers the app when you leave it. Glucose collection, loop operation and alarms run independently. A forgotten code can be reset after iPhone device-owner authentication."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(privacyText("Privacy Protection"))
        .onAppear {
            if PrivacyMeterStyle(rawValue: meterStyle) == nil {
                meterStyle = PrivacyMeterStyle.history.rawValue
            }
        }
        .sheet(isPresented: $showSetup) { PrivacyLockSetup(method: method, controller: lock) }
        .task(id: selectedPhoto) { await loadCover() }
    }

    private func protected(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: { value in
            lock.requireAuthentication {
                binding.wrappedValue = value
                PrivacyPreference.record(stage: "settings", outcome: "changed")
                PrivacyPreference.notifyChanged()
            }
        })
    }

    private var selectedColors: [PrivacyColor] {
        (PrivacyPalettePreset(rawValue: palette) ?? .quiet).colors
    }

    private func protectedChoice(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { value in
            lock.requireAuthentication {
                binding.wrappedValue = value
                PrivacyPreference.record(stage: "settings", outcome: "changed")
                PrivacyPreference.notifyChanged()
            }
        })
    }

    private func saveBoundaries() {
        let values = boundaryText.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard PrivacyPalette.isValid(values) else {
            message = privacyText("Enter five increasing boundaries between 1 and 30, separated by at least 0.5 mmol/L.")
            return
        }
        lock.requireAuthentication {
            UserDefaults.standard.set(values, forKey: PrivacyPreference.boundariesKey)
            message = privacyText("Color ranges saved.")
            PrivacyPreference.record(stage: "settings", outcome: "changed")
            PrivacyPreference.notifyChanged()
        }
    }

    @MainActor private func loadCover() async {
        guard let photo = selectedPhoto else { return }
        let generation = UUID()
        coverSelectionGeneration = generation
        loadingCover = true
        message = nil
        defer {
            if generation == coverSelectionGeneration {
                loadingCover = false
                // Do not clear a newer selection whose task has not started yet.
                if selectedPhoto == photo { selectedPhoto = nil }
            }
        }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw PrivacyVaultError.storage }
            try Task.checkCancellation()
            guard generation == coverSelectionGeneration, selectedPhoto == photo else { return }
            guard let thumbnail = PrivacyCoverImage.thumbnail(data) else {
                message = privacyText("This image could not be processed into a cover. Try another image.")
                PrivacyPreference.record(stage: "cover", outcome: "failed")
                return
            }
            lock.requireAuthentication {
                guard generation == coverSelectionGeneration, selectedPhoto == nil || selectedPhoto == photo else { return }
                UserDefaults.standard.set(thumbnail, forKey: PrivacyPreference.coverKey)
                cover = thumbnail
                message = nil
                PrivacyPreference.record(stage: "cover", outcome: "succeeded")
                PrivacyPreference.notifyChanged()
            }
        } catch {
            guard !Task.isCancelled, generation == coverSelectionGeneration, selectedPhoto == photo else { return }
            message = privacyText("The photo could not be read or downloaded. Check your connection and try again.")
            PrivacyPreference.record(stage: "cover", outcome: "failed")
        }
    }
}

private struct PrivacyLockSetup: View {
    let method: PrivacyLockMethod
    @ObservedObject var controller: PrivacyLockController
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var value = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(privacyText(first == nil ? "Enter a new code." : "Repeat the code to confirm."))
                if method == .pattern {
                    Text(privacyText("Use at least four dots. Trace visibility follows Privacy settings."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                PrivacySecretInput(method: method, value: $value, onComplete: accept).disabled(busy)
                if let message { Text(message).font(.footnote) }
            }
            .padding()
            .navigationTitle(privacyText("Set up viewing lock"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(privacyText("Cancel")) { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func accept(_ code: String) {
        guard !busy else { return }
        value = ""
        guard let first else { self.first = code; message = nil; return }
        guard first == code else {
            self.first = nil
            message = privacyText("The codes did not match. Start again.")
            return
        }
        busy = true
        Task {
            do {
                try await controller.configure(method: method, secret: code)
                dismiss()
            } catch { message = privacyText("The viewing lock could not be saved.") }
            busy = false
        }
    }
}

public struct PrivacyQuickButton: View {
    @AppStorage(PrivacyPreference.displayKey) private var enabled = false
    public init() {}
    public var body: some View {
        Button {
            // Enabling privacy is safe in public. Revealing numbers requires the viewing lock.
            if enabled {
                PrivacyLockController.shared.requireAuthentication { setEnabled(false) }
            } else { setEnabled(true) }
        } label: {
            Image(systemName: enabled ? "eye.slash" : "eye")
                .font(.system(size: 14)).frame(width: 36, height: 36)
        }
        .accessibilityLabel(Text(privacyText(enabled ? "Show full activity" : "Enable private activity")))
    }
    private func setEnabled(_ value: Bool) {
        enabled = value
        PrivacyPreference.record(stage: "settings", outcome: "changed")
        PrivacyPreference.notifyChanged()
    }
}
#endif

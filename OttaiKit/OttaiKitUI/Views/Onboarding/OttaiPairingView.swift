//
//  OttaiPairingView.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import AVFoundation
import LoopKitUI
import SwiftUI
import OttaiKit
import UniformTypeIdentifiers

struct OttaiPairingView: View {
    @ObservedObject var viewModel: OttaiPairingViewModel

    @State private var showingScanner = false
    @State private var showingCameraDenied = false

    var body: some View {
        VStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Image(imageName: viewModel.sensorArtworkName)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 150)
                                .padding(.bottom, 20)
                            Spacer()
                        }
                        if viewModel.phase == .choosingMethod {
                            Text("Find your sensor", bundle: .ottaiUI, comment: "pairing method header")
                                .font(.title3).bold()
                            Text(
                                "Scan the QR code on the sensor applicator, or search for sensors nearby.", bundle: .ottaiUI,
                                comment: "pairing method body"
                            )
                            Text(verbatim: OttaiLocalizedString(
                                "If the sensor is asleep, hold the top of the iPhone near it to wake it with NFC.",
                                comment: "pairing method nfc hint"
                            ))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        } else {
                            Text("Please be patient", bundle: .ottaiUI, comment: "pairing header")
                                .font(.title3).bold()
                            Text(
                                "Keep your phone near the sensor. This can take up to a minute.", bundle: .ottaiUI,
                                comment: "pairing body"
                            )
                        }
                    }
                }

                if viewModel.phase == .confirming, let mac = viewModel.scannedMAC {
                    Section {
                        Text(mac)
                        Text(verbatim: OttaiLocalizedString(
                            "NFC only wakes the sensor. Pairing still checks its Bluetooth address.",
                            comment: "scanned sensor nfc footnote"
                        ))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    } header: {
                        Text("Scanned sensor", bundle: .ottaiUI, comment: "scanned applicator header")
                    }
                } else if viewModel.phase == .confirming, let candidate = viewModel.selectedCandidate {
                    Section {
                        // selectedCandidate is always a fresh (unknown) MAC.
                        // A known/retired advertiser is never auto-presented,
                        // so no retired badge is possible on this card.
                        HStack {
                            Text(candidate.mac)
                            Spacer()
                            if let rssi = candidate.rssi {
                                Text("\(rssi) dBm", bundle: .ottaiUI)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Is this your sensor?", bundle: .ottaiUI, comment: "confirm candidate header")
                    }
                }

                if viewModel.phase == .picking {
                    Section {
                        if !viewModel.statusText.isEmpty {
                            Text(viewModel.statusText)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        if viewModel.visibleCandidates.isEmpty {
                            Text(verbatim: viewModel.candidates.isEmpty
                                ? String(
                                    localized: "No sensors heard. The sensor advertises in bursts. Try scanning again.", bundle: .ottaiUI,
                                    comment: "no candidates text"
                                )
                                : OttaiLocalizedString(
                                    "Only previously used sensors were heard. Replace the sensor or scan its applicator.",
                                    comment: "only retired candidates text"
                                ))
                                .foregroundColor(.secondary)
                        }
                        ForEach(viewModel.visibleCandidates) { candidate in
                            let isKnown = viewModel.excludedMACs.contains(candidate.mac)
                            Button(action: { viewModel.selectedMAC = candidate.mac }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.mac)
                                        if isKnown {
                                            Text("Previously used, can't be re-paired", bundle: .ottaiUI, comment: "retired sensor badge")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    Spacer()
                                    if let rssi = candidate.rssi {
                                        Text("\(rssi) dBm", bundle: .ottaiUI)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if viewModel.selectedMAC == candidate.mac {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                            // A known MAC is a bound/retired sensor that can't
                            // be re-paired: badged but not selectable.
                            .disabled(isKnown)
                        }
                    } header: {
                        Text("Select your sensor", bundle: .ottaiUI, comment: "candidate list header")
                    }
                }

                if viewModel.phase == .pairing, let mac = viewModel.selectedMAC {
                    Section {
                        // The MAC stays on screen for the whole flow: if it
                        // isn't the user's sensor, they bail out instead of
                        // activating the wrong one.
                        HStack {
                            Text("Found sensor", bundle: .ottaiUI, comment: "discovered sensor label")
                            Spacer()
                            Text(mac).foregroundColor(.secondary)
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error).foregroundColor(.red)
                        if viewModel.phase == .pairing {
                            Button(action: viewModel.retry) {
                                Text("Try Again", bundle: .ottaiUI, comment: "retry button")
                            }
                            Button(action: viewModel.backToConfirmation) {
                                Text("Change Sensor", bundle: .ottaiUI, comment: "back to sensor confirmation button")
                            }
                        } else if viewModel.phase == .confirming || viewModel.phase == .picking {
                            Button(action: viewModel.wakeWithNFC) {
                                Text(verbatim: OttaiLocalizedString("Try NFC Again", comment: "retry nfc wake button"))
                            }
                            Button(action: viewModel.searchAgain) {
                                Text(verbatim: OttaiLocalizedString("Search Again", comment: "retry bluetooth search button"))
                            }
                        }
                    }
                }
            }
            Spacer()

            switch viewModel.phase {
            case .choosingMethod:
                VStack(spacing: 10) {
                    Button(action: scanApplicatorTapped) {
                        Label(
                            String(localized: "Scan Applicator", bundle: .ottaiUI, comment: "scan applicator button"),
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(ActionButtonStyle())
                    Button(action: viewModel.wakeWithNFC) {
                        Label(
                            OttaiLocalizedString("Wake with NFC", comment: "nfc wake button"),
                            systemImage: "wave.3.right"
                        )
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                    .disabled(viewModel.isWakingWithNFC)
                    Button(action: viewModel.scan) {
                        Text("Search Nearby", bundle: .ottaiUI, comment: "search nearby sensors button")
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                    Button(action: viewModel.signOut) {
                        Text(verbatim: OttaiLocalizedString("Sign Out of Ottai", comment: "sign out and sign in again"))
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                }
                .padding(.horizontal)
                .padding(.bottom)
            case .scanning:
                VStack(spacing: 5) {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                    Text(viewModel.statusText).font(.footnote)
                }
                .padding(.bottom)
            case .verifyingApplicator:
                VStack(spacing: 5) {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                    Text(verbatim: OttaiLocalizedString(
                        "Checking sensor with Ottai…",
                        comment: "verifying scanned applicator status"
                    )).font(.footnote)
                }
                .padding(.bottom)
            case .confirming:
                VStack(spacing: 10) {
                    if !viewModel.statusText.isEmpty {
                        Text(viewModel.statusText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Button(action: viewModel.pair) {
                        Text("Pair", bundle: .ottaiUI, comment: "pair button")
                    }
                    .buttonStyle(ActionButtonStyle())
                    Button(action: viewModel.wakeWithNFC) {
                        Text(verbatim: OttaiLocalizedString("Wake with NFC", comment: "nfc wake button"))
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                    .disabled(viewModel.isWakingWithNFC)
                    if viewModel.scannedMAC != nil {
                        Button(action: scanApplicatorTapped) {
                            Text("Scan Again", bundle: .ottaiUI, comment: "rescan applicator button")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))
                    }
                    // Only offer the list escape when there's actually another
                    // advertiser to choose: a single heard sensor has no
                    // alternative to pick.
                    if viewModel.candidates.count > 1 {
                        Button(action: viewModel.showAllSensors) {
                            Text("My sensor isn't listed", bundle: .ottaiUI, comment: "show all sensors fallback button")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            case .picking:
                VStack(spacing: 10) {
                    Button(action: viewModel.pair) {
                        Text("Pair", bundle: .ottaiUI, comment: "pair button")
                    }
                    .buttonStyle(ActionButtonStyle())
                    .disabled(viewModel.selectedMAC == nil)
                    Button(action: viewModel.wakeWithNFC) {
                        Text(verbatim: OttaiLocalizedString("Wake with NFC", comment: "nfc wake button"))
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                    .disabled(viewModel.isWakingWithNFC)
                    Button(action: viewModel.scan) {
                        Text("Scan Again", bundle: .ottaiUI, comment: "rescan button")
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                    if viewModel.canScanApplicator {
                        Button(action: scanApplicatorTapped) {
                            Text("Scan Applicator Instead", bundle: .ottaiUI, comment: "switch to applicator scan button")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            case .pairing:
                if viewModel.errorMessage == nil {
                    VStack(spacing: 5) {
                        ActivityIndicator(isAnimating: .constant(true), style: .medium)
                        Text(viewModel.statusText).font(.footnote)
                    }
                    .padding(.bottom)
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            NavigationView {
                OttaiApplicatorScannerView { mac in
                    showingScanner = false
                    viewModel.didScanApplicator(mac: mac)
                }
                .ignoresSafeArea()
                .navigationBarTitle(Text("Scan Applicator", bundle: .ottaiUI, comment: "applicator scanner title"), displayMode: .inline)
                .navigationBarItems(trailing: Button(String(localized: "Cancel", bundle: .ottaiUI, comment: "cancel applicator scan")) {
                    showingScanner = false
                })
            }
        }
        .alert(
            String(localized: "Camera Access Is Off", bundle: .ottaiUI, comment: "camera denied alert title"),
            isPresented: $showingCameraDenied
        ) {
            Button(String(localized: "Open Settings", bundle: .ottaiUI, comment: "open iOS settings button")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "Cancel", bundle: .ottaiUI, comment: "cancel camera alert"), role: .cancel) {}
        } message: {
            Text(
                "Allow camera access in Settings to scan the applicator, or search for sensors nearby instead.", bundle: .ottaiUI,
                comment: "camera denied alert message"
            )
        }
    }

    /// The scanner shows a blank view without camera access, so ask first.
    private func scanApplicatorTapped() {
        #if targetEnvironment(simulator)
            viewModel.didScanApplicator(mac: OttaiCGMManager.simulatedApplicatorMAC())
        #else
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                showingScanner = true
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            showingScanner = true
                        } else {
                            showingCameraDenied = true
                        }
                    }
                }
            default:
                showingCameraDenied = true
            }
        #endif
    }
}

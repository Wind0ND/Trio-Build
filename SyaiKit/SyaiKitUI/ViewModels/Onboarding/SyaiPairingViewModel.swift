//
//  SyaiPairingViewModel.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
@preconcurrency import CoreNFC
import SwiftUI
import SyaiKit

@MainActor final class SyaiPairingViewModel: ObservableObject {
    enum Phase {
        case choosingMethod
        case scanning
        /// Verifying an applicator-scanned MAC against the server because local
        /// history (or a refusal earlier this session) flags it as used.
        case verifyingApplicator
        case confirming
        case picking
        case pairing
    }

    @Published var phase: Phase = .scanning
    @Published var candidates: [SyaiSensorCandidate] = []
    @Published var selectedMAC: String?
    /// Set when the MAC came from the applicator's QR code rather than from
    /// BLE discovery; the confirmation card shows it instead of a candidate.
    @Published var scannedMAC: String?
    @Published var statusText = String(localized: "Starting…", comment: "pairing initial status")
    @Published var errorMessage: String?
    @Published var isFinished = false

    /// Every MAC this phone has ever paired. Activation-pairing a known sensor
    /// never makes sense: an active one is managed (End Sensor first), one from
    /// a deleted manager is auto-resumed at merge, an expired one is refused by
    /// the server, and a bound one is re-attached via the account-side lookup
    /// (getBindDevice/authInfo), never by user selection.
    let knownMACs: Set<String>
    /// MACs the server permanently refused during this session (ended or
    /// already activated). Not necessarily in the local history, so tracked
    /// separately; excluded from auto-pick and selection just like known ones.
    private(set) var refusedMACs: Set<String> = []
    var excludedMACs: Set<String> { knownMACs.union(refusedMACs) }

    var bestCandidate: SyaiSensorCandidate? {
        candidates.first { !excludedMACs.contains($0.mac) }
    }

    private let cgmManager: SyaiCGMManager
    private let onCreated: () -> Void
    private let onNeedsLogin: () -> Void
    private var task: Task<Void, Never>?

    init(cgmManager: SyaiCGMManager, onCreated: @escaping () -> Void, onNeedsLogin: @escaping () -> Void = {}) {
        self.cgmManager = cgmManager
        self.onCreated = onCreated
        self.onNeedsLogin = onNeedsLogin
        knownMACs = Set(cgmManager.state.sensors.history().map(\.mac))
        // Without a usable camera there's nothing to choose between.
        if canScanApplicator {
            phase = .choosingMethod
        } else {
            scan()
        }
    }

    var canScanApplicator: Bool { SyaiApplicatorScannerView.isAvailable }

    /// The scanned MAC is the user's own sensor by construction, so it goes
    /// straight to confirmation: no discovery, no RSSI guess.
    func didScanApplicator(mac: String) {
        task?.cancel()
        candidates = []
        guard !excludedMACs.contains(mac) else {
            verifyFlaggedApplicator(mac: mac)
            return
        }
        acceptScannedMAC(mac)
    }

    private func acceptScannedMAC(_ mac: String) {
        errorMessage = nil
        scannedMAC = mac
        selectedMAC = mac
        phase = .confirming
    }

    /// Scanning an applicator is unambiguous "this is my new sensor" intent, so
    /// a local flag (known history record or a refusal earlier this session) is
    /// not the last word: ask the server. It refuses a truly used sensor at
    /// validate, before any activation write; a false local flag costs one
    /// read-only call and then pairs normally.
    private func verifyFlaggedApplicator(mac: String) {
        errorMessage = nil
        scannedMAC = mac
        phase = .verifyingApplicator
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cgmManager.validateSensor(mac: mac)
                guard !Task.isCancelled else { return }
                self.acceptScannedMAC(mac)
            } catch {
                guard !Task.isCancelled else { return }
                // A dead account session can't be fixed from here; go sign in again.
                if let transport = error as? SyaiEnvelopedClient.TransportError, transport.isAccountLoggedInElsewhere {
                    self.onNeedsLogin()
                    return
                }
                self.scannedMAC = nil
                self.selectedMAC = nil
                self.errorMessage = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                self.phase = .choosingMethod
            }
        }
    }

    func scan() {
        phase = .scanning
        errorMessage = nil
        candidates = []
        selectedMAC = nil
        scannedMAC = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.cgmManager.discoverSensorCandidates()
                guard !Task.isCancelled else { return }
                self.candidates = found
                // Auto-present only a fresh (unknown-MAC) advertiser. If the
                // only sensors heard are known/refused ones, drop to the
                // list so the user sees the badges instead of a dead auto-pick.
                if let best = found.first(where: { !self.excludedMACs.contains($0.mac) }) {
                    self.selectedMAC = best.mac
                    self.phase = .confirming
                } else {
                    self.phase = .picking
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = (error as CustomStringConvertible).description
                self.phase = .picking
            }
        }
    }

    func pair() {
        guard let mac = selectedMAC else { return }
        phase = .pairing
        errorMessage = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cgmManager.activateSensor(preselectedMAC: mac, onStage: { [weak self] stage in
                    Task { @MainActor in
                        self?.statusText = Self.text(for: stage)
                    }
                })
                guard !Task.isCancelled else { return }
                self.isFinished = true
                self.onCreated()
            } catch {
                guard !Task.isCancelled else { return }
                if case let .service(failure) = error as? SyaiCGMManager.AttachError {
                    // A dead account session can't be fixed from here; go sign in again.
                    if case .accountLoggedOutElsewhere = failure {
                        self.onNeedsLogin()
                        return
                    }
                    // The server permanently refused this MAC: stop offering it and
                    // drop to the list so another advertiser can be picked.
                    if case .pairingRefused = failure {
                        self.refusedMACs.insert(mac)
                        self.selectedMAC = nil
                        self.errorMessage = failure.description
                        self.phase = .picking
                        return
                    }
                }
                self.errorMessage = (error as CustomStringConvertible).description
            }
        }
    }

    @Published var diagnostics: String?

    /// Reads every account-device endpoint and puts the answer on the
    /// clipboard, so a refusal can be read without pulling log files off the
    /// phone. Read-only: it never binds, unbinds or connects anything.
    func runDiagnostics() {
        statusText = String(localized: "Reading the account…", comment: "diagnostics status")
        Task { [weak self] in
            guard let self else { return }
            guard let lookup = self.cgmManager.diagnosticsLookup() else {
                self.diagnostics = "no account session"
                self.statusText = ""
                return
            }
            let raw = await lookup.cnAccountDiagnostics(mac: self.selectedMAC)
            let managerLine = "manager=\(type(of: self.cgmManager)) id=\(self.cgmManager.pluginIdentifier) templateIsCn=\(type(of: self.cgmManager).backendTemplate.isOttaiCn) sessionIsCn=\(self.cgmManager.account?.isOttaiCn.map { $0 ? "true" : "false" } ?? "nil")"
            let text = managerLine + "\n" + raw
            self.diagnostics = text
            UIPasteboard.general.string = text
            self.statusText = String(
                localized: "Diagnostics copied to the clipboard.",
                comment: "diagnostics done"
            )
        }
    }

    /// The Keychain session outlives CGM deletion and a reinstall, so onboarding
    /// needs its own way to drop it and sign in again.
    func signOut() {
        task?.cancel()
        errorMessage = nil
        cgmManager.logOut()
        onNeedsLogin()
    }

    func retry() { pair() }

    func showAllSensors() {
        phase = .picking
    }

    func backToConfirmation() {
        task?.cancel()
        errorMessage = nil
        if scannedMAC != nil {
            phase = .confirming
        } else {
            phase = bestCandidate == nil ? .picking : .confirming
        }
    }

    private static func text(for stage: SyaiPairingService.Stage) -> String {
        switch stage {
        case .discoveringSensor: return String(localized: "Searching for nearby sensors…", comment: "stage discovery")
        case let .sensorFound(mac): return String(
                format: String(localized: "Found sensor %@", comment: "stage sensor found"),
                mac
            )
        case .bleSearching: return String(localized: "Searching for sensor", comment: "stage searching")
        case .bleConnecting: return String(localized: "Connecting", comment: "stage connecting")
        case .handshaking: return String(localized: "Authenticating", comment: "stage handshaking")
        case .resolvingCalibration: return String(localized: "Loading calibration", comment: "stage calibration")
        case .binding: return String(localized: "Registering sensor", comment: "stage binding")
        case .activating: return String(localized: "Activating sensor", comment: "stage activating")
        }
    }
}

// MARK: - CN / Syai NFC wake

/// Ottai CN and Syai sensors stay asleep until a reader's RF field wakes them.
/// While asleep they neither advertise nor accept a connection, so BLE
/// discovery finds nothing however long it scans. This reader only opens the
/// field: it never connects to the tag and never reads or writes tag data.
final class SyaiNFCWaker: NSObject, NFCTagReaderSessionDelegate {
    static let shared = SyaiNFCWaker()

    private var session: NFCTagReaderSession?
    private var completion: ((Bool) -> Void)?

    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    func begin(completion: @escaping (Bool) -> Void) {
        guard Self.isAvailable else {
            completion(false)
            return
        }
        self.completion = completion
        let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        session?.alertMessage = String(
            localized: "Hold the top of this iPhone against the sensor for a second.",
            comment: "nfc wake prompt"
        )
        self.session = session
        session?.begin()
    }

    private func finish(_ woke: Bool) {
        completion?(woke)
        completion = nil
        session = nil
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        // The field is the whole point; the tag identity is not verified here.
        session.alertMessage = String(localized: "Sensor woken.", comment: "nfc wake done")
        session.invalidate()
        finish(true)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if completion != nil { finish(false) }
    }
}

extension SyaiPairingViewModel {
    /// Wakes a sleeping CN/Syai sensor with an NFC RF field, then rescans.
    func wakeWithNFC() {
        guard SyaiNFCWaker.isAvailable else {
            errorMessage = String(
                localized: "This iPhone can't read NFC tags.",
                comment: "nfc unavailable"
            )
            return
        }
        statusText = String(localized: "Waiting for the sensor…", comment: "nfc wake status")
        SyaiNFCWaker.shared.begin { [weak self] woke in
            Task { @MainActor in
                guard let self else { return }
                if woke {
                    self.scan()
                } else {
                    self.statusText = String(
                        localized: "No tag detected. Hold the iPhone against the sensor and try again.",
                        comment: "nfc wake failed"
                    )
                }
            }
        }
    }
}

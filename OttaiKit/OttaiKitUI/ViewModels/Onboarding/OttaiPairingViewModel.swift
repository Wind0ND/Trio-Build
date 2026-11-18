//
//  OttaiPairingViewModel.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
@preconcurrency import CoreNFC
import SwiftUI
import OttaiKit

@MainActor final class OttaiPairingViewModel: ObservableObject {
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
    @Published var candidates: [OttaiSensorCandidate] = []
    @Published var selectedMAC: String?
    /// Set when the MAC came from the applicator's QR code rather than from
    /// BLE discovery; the confirmation card shows it instead of a candidate.
    @Published var scannedMAC: String?
    @Published var statusText = String(localized: "Starting…", bundle: .ottaiUI, comment: "pairing initial status")
    @Published var errorMessage: String?
    @Published var isFinished = false
    /// True while the system NFC sheet is up. Repeated taps are ignored rather
    /// than replacing the completion of the in-flight read.
    @Published var isWakingWithNFC = false
    /// After a no-QR wake only eligible advertisers are offered, so a retired
    /// sensor cannot be presented as "the one the tag woke".
    @Published var showsOnlyEligibleCandidates = false

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

    var eligibleCandidates: [OttaiSensorCandidate] {
        OttaiWakeTargetMatcher.eligible(candidates, excluding: excludedMACs)
    }

    /// What the picker renders. The normal search keeps known sensors visible
    /// with a badge; the no-QR NFC flow shows only sensors that may be paired.
    var visibleCandidates: [OttaiSensorCandidate] {
        showsOnlyEligibleCandidates ? eligibleCandidates : candidates
    }

    var bestCandidate: OttaiSensorCandidate? { eligibleCandidates.first }

    /// The candidate the user (or the NFC match) actually selected. Falling
    /// back to `bestCandidate` keeps the ordinary auto-pick screen unchanged.
    var selectedCandidate: OttaiSensorCandidate? {
        if let selectedMAC {
            let target = OttaiWakeTargetMatcher.normalized(selectedMAC)
            if let exact = candidates.first(where: { OttaiWakeTargetMatcher.normalized($0.mac) == target }) {
                return exact
            }
        }
        return bestCandidate
    }

    private let cgmManager: OttaiCGMManager

    /// Artwork asset matching the configured sensor.
    var sensorArtworkName: String { cgmManager.brandArtwork }
    private let onCreated: () -> Void
    private let onNeedsLogin: () -> Void
    private var task: Task<Void, Never>?

    /// Identifies the current NFC attempt so a callback from a cancelled or
    /// superseded session cannot mutate the screen.
    private var wakeGeneration = UUID()
    private var wakeAttempts = 0
    private var reachedBindingStage = false

    init(cgmManager: OttaiCGMManager, onCreated: @escaping () -> Void, onNeedsLogin: @escaping () -> Void = {}) {
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

    var canScanApplicator: Bool { OttaiApplicatorScannerView.isAvailable }

    /// The scanned MAC is the user's own sensor by construction, so it goes
    /// straight to confirmation: no discovery, no RSSI guess.
    func didScanApplicator(mac: String) {
        invalidatePendingWake()
        task?.cancel()
        candidates = []
        showsOnlyEligibleCandidates = false
        guard !excludedMACs.contains(mac) else {
            verifyFlaggedApplicator(mac: mac)
            return
        }
        acceptScannedMAC(mac)
    }

    private func acceptScannedMAC(_ mac: String) {
        errorMessage = nil
        statusText = ""
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
                if let transport = error as? OttaiEnvelopedClient.TransportError, transport.isAccountLoggedInElsewhere {
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
        invalidatePendingWake()
        phase = .scanning
        errorMessage = nil
        candidates = []
        selectedMAC = nil
        scannedMAC = nil
        showsOnlyEligibleCandidates = false
        statusText = String(localized: "Searching for nearby sensors…", bundle: .ottaiUI, comment: "scanning status")
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
                if let best = self.bestCandidate {
                    self.selectedMAC = best.mac
                    self.statusText = ""
                    self.phase = .confirming
                } else {
                    self.statusText = ""
                    self.phase = .picking
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.statusText = ""
                self.errorMessage = (error as CustomStringConvertible).description
                self.phase = .picking
            }
        }
    }

    /// BLE discovery after an NFC field was applied. When a target was chosen
    /// (QR or picker), the target must advertise before the UI may report it
    /// awake; a no-target wake only ever presents eligible candidates.
    private func scanForTarget(targetMAC: String?, wasScanned: Bool) {
        task?.cancel()
        phase = .scanning
        errorMessage = nil
        candidates = []
        selectedMAC = targetMAC
        showsOnlyEligibleCandidates = targetMAC == nil
        statusText = OttaiLocalizedString("Looking for the sensor's Bluetooth signal…", comment: "nfc wake scanning status")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // A chosen target uses the direct, exact-MAC discovery path:
                // it waits for that sensor (or the normal timeout) instead of
                // returning after the generic discovery settle window.
                let found: [OttaiSensorCandidate]
                if let targetMAC {
                    if let match = try await self.cgmManager.discoverSensor(mac: targetMAC) {
                        found = [match]
                    } else {
                        found = []
                    }
                } else {
                    found = try await self.cgmManager.discoverSensorCandidates()
                }
                guard !Task.isCancelled else { return }
                self.candidates = found
                if let targetMAC {
                    if let match = OttaiWakeTargetMatcher.match(targetMAC: targetMAC, candidates: found) {
                        self.selectedMAC = match.mac
                        self.phase = .confirming
                        self.errorMessage = nil
                        self.statusText = wasScanned
                            ? OttaiLocalizedString("The scanned sensor is awake. Confirm it is yours.",
                                comment: "nfc wake matched QR sensor"
                            )
                            : OttaiLocalizedString("Sensor is awake. Confirm it is yours.",
                                comment: "nfc wake matched selected sensor"
                            )
                        OttaiDiagnosticEvent.record(.bleMatch, .matched, count: found.count)
                    } else {
                        self.selectedMAC = targetMAC
                        self.phase = wasScanned ? .confirming : .picking
                        self.showsOnlyEligibleCandidates = !wasScanned
                        self.statusText = ""
                        self.errorMessage = OttaiLocalizedString("That sensor hasn't advertised yet. Keep it near the iPhone and tap Try NFC Again.",
                            comment: "nfc wake target not discovered"
                        )
                        OttaiDiagnosticEvent.record(.bleNonMatch, .notMatched, count: found.count)
                    }
                } else {
                    self.selectedMAC = nil
                    self.phase = .picking
                    if found.isEmpty {
                        self.errorMessage = String(
                            localized: "No sensors heard. The sensor advertises in bursts. Try scanning again.", bundle: .ottaiUI,
                            comment: "no candidates text"
                        )
                        OttaiDiagnosticEvent.record(.bleNonMatch, .notMatched, count: 0)
                    } else if self.eligibleCandidates.isEmpty {
                        self.errorMessage = OttaiLocalizedString("Only previously used sensors were heard. Replace the sensor or scan its applicator.",
                            comment: "nfc wake only retired candidates"
                        )
                        OttaiDiagnosticEvent.record(.bleNonMatch, .notMatched, count: found.count)
                    } else {
                        self.statusText = OttaiLocalizedString("Bluetooth sensors found. Choose the sensor you just applied.",
                            comment: "nfc wake choose discovered candidate"
                        )
                        OttaiDiagnosticEvent.record(.bleMatch, .matched, count: self.eligibleCandidates.count)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.selectedMAC = targetMAC
                self.phase = targetMAC == nil || !wasScanned ? .picking : .confirming
                self.showsOnlyEligibleCandidates = targetMAC == nil || !wasScanned
                self.statusText = ""
                self.errorMessage = (error as CustomStringConvertible).description
            }
        }
    }

    func pair() {
        guard let mac = selectedMAC else { return }
        phase = .pairing
        errorMessage = nil
        reachedBindingStage = false
        if cgmManager.state.sensors.pendingBind(forMAC: mac) != nil {
            // The sensor is already activated; this run resumes at the bind.
            OttaiDiagnosticEvent.record(.binding, .retried)
        } else {
            OttaiDiagnosticEvent.record(.activation, .started)
        }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cgmManager.activateSensor(preselectedMAC: mac, onStage: { [weak self] stage in
                    Task { @MainActor in
                        guard let self else { return }
                        self.statusText = Self.text(for: stage)
                        if stage == .binding, !self.reachedBindingStage {
                            self.reachedBindingStage = true
                            OttaiDiagnosticEvent.record(.binding, .started)
                        }
                    }
                })
                guard !Task.isCancelled else { return }
                self.isFinished = true
                OttaiDiagnosticEvent.record(.activation, .succeeded)
                if self.reachedBindingStage {
                    OttaiDiagnosticEvent.record(.binding, .succeeded)
                }
                OttaiDiagnosticEvent.record(.completion, .succeeded)
                self.onCreated()
            } catch {
                guard !Task.isCancelled else { return }
                if self.reachedBindingStage {
                    OttaiDiagnosticEvent.record(.binding, .failed)
                } else {
                    OttaiDiagnosticEvent.record(.activation, .failed)
                }
                if case let .service(failure) = error as? OttaiCGMManager.AttachError {
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

    /// The Keychain session outlives CGM deletion and a reinstall, so onboarding
    /// needs its own way to drop it and sign in again.
    func signOut() {
        invalidatePendingWake()
        task?.cancel()
        errorMessage = nil
        cgmManager.logOut()
        onNeedsLogin()
    }

    func retry() { pair() }

    func showAllSensors() {
        phase = .picking
        showsOnlyEligibleCandidates = false
    }

    /// Retry BLE discovery without another NFC tap. A target that was already
    /// chosen stays chosen and must still be matched before "awake" is shown.
    func searchAgain() {
        invalidatePendingWake()
        if let target = scannedMAC ?? selectedMAC {
            scanForTarget(targetMAC: target, wasScanned: scannedMAC != nil)
        } else {
            scan()
        }
    }

    func backToConfirmation() {
        invalidatePendingWake()
        task?.cancel()
        errorMessage = nil
        if scannedMAC != nil {
            phase = .confirming
        } else {
            phase = selectedCandidate == nil ? .picking : .confirming
        }
    }

    private static func text(for stage: OttaiPairingService.Stage) -> String {
        switch stage {
        case .discoveringSensor: return String(localized: "Searching for nearby sensors…", bundle: .ottaiUI, comment: "stage discovery")
        case let .sensorFound(mac): return String(
                format: String(localized: "Found sensor %@", bundle: .ottaiUI, comment: "stage sensor found"),
                mac
            )
        case .bleSearching: return String(localized: "Searching for sensor", bundle: .ottaiUI, comment: "stage searching")
        case .bleConnecting: return String(localized: "Connecting", bundle: .ottaiUI, comment: "stage connecting")
        case .handshaking: return String(localized: "Authenticating", bundle: .ottaiUI, comment: "stage handshaking")
        case .resolvingCalibration: return String(localized: "Loading calibration", bundle: .ottaiUI, comment: "stage calibration")
        case .binding: return String(localized: "Registering sensor", bundle: .ottaiUI, comment: "stage binding")
        case .activating: return String(localized: "Activating sensor", bundle: .ottaiUI, comment: "stage activating")
        }
    }

    /// A new action supersedes any in-flight NFC completion. The NFC session
    /// itself is left to iOS to invalidate; its late callback is ignored.
    private func invalidatePendingWake() {
        wakeGeneration = UUID()
        isWakingWithNFC = false
        // A route change/rescan must not leave an NFC sheet waiting forever.
        OttaiNFCWaker.shared.cancelActive()
    }
}

// MARK: - NFC wake

/// Ottai sensors stay asleep until a reader's RF field wakes them. While
/// asleep they neither advertise nor accept a connection, so BLE discovery
/// finds nothing however long it scans. This reader only opens the field: it
/// never connects to the tag and never reads or writes tag data.
///
/// The tag identity is deliberately not used as proof of which transmitter was
/// woken; BLE discovery against the selected MAC is the only confirmation.
final class OttaiNFCWaker: NSObject, NFCTagReaderSessionDelegate {
    enum Result {
        case woke
        case cancelled
        case unavailable
        case failed
        case busy
    }

    static let shared = OttaiNFCWaker()

    /// All reader state lives on this one serial context. CoreNFC callbacks and
    /// view resets can arrive from different threads; identity checks below
    /// make sure a late callback can only finish the session it belongs to.
    private let stateQueue = DispatchQueue(label: "org.loopkit.OttaiKit.nfc")
    private var activeSession: NFCTagReaderSession?
    private var completion: ((Result) -> Void)?

    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    /// Only one read is allowed at a time. A repeated tap is completed as
    /// `.busy` rather than replacing the completion of the live session.
    func begin(completion: @escaping (Result) -> Void) {
        guard Self.isAvailable else {
            completion(.unavailable)
            return
        }
        stateQueue.sync {
            guard activeSession == nil else {
                completion(.busy)
                return
            }
            guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) else {
                completion(.failed)
                return
            }
            activeSession = session
            self.completion = completion
            session.alertMessage = OttaiLocalizedString("Hold the top of this iPhone against the sensor for a second.",
                comment: "nfc wake prompt"
            )
            session.begin()
        }
    }

    /// Cancel whatever is live during a view reset/route change. The active
    /// session is taken and cleared *before* invalidating, so its late
    /// invalidation callback cannot end a newer session.
    func cancelActive() {
        stateQueue.async {
            guard let session = self.activeSession else { return }
            self.activeSession = nil
            let completion = self.completion
            self.completion = nil
            session.invalidate()
            completion?(.cancelled)
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        stateQueue.async {
            guard self.activeSession === session else { return }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect _: [NFCTag]) {
        stateQueue.async {
            guard self.activeSession === session else { return }
            // Take the session out of the active slot before invalidating.
            self.activeSession = nil
            let completion = self.completion
            self.completion = nil
            // The field is the whole point; the tag identity is not verified.
            session.alertMessage = OttaiLocalizedString("NFC signal sent. Keep the iPhone near the sensor.",
                comment: "nfc wake signal sent"
            )
            session.invalidate()
            completion?(.woke)
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        stateQueue.async {
            guard self.activeSession === session else { return }
            self.activeSession = nil
            let completion = self.completion
            self.completion = nil
            let result: Result
            if let readerError = error as? NFCReaderError,
               readerError.code == .readerSessionInvalidationErrorUserCanceled
            {
                result = .cancelled
            } else {
                result = .failed
            }
            completion?(result)
        }
    }
}

extension OttaiPairingViewModel {
    /// Wakes a sleeping sensor with an NFC RF field. The QR-selected MAC (or a
    /// picker selection) is retained and must appear in BLE discovery before
    /// the UI reports that target awake. With no selected MAC, discovery only
    /// offers eligible candidates and never claims the tag identified one.
    func wakeWithNFC() {
        guard !isWakingWithNFC else { return }
        guard OttaiNFCWaker.isAvailable else {
            OttaiDiagnosticEvent.record(.nfc, .unavailable, attempt: wakeAttempts + 1)
            statusText = ""
            errorMessage = OttaiLocalizedString("This iPhone can't read NFC tags.",
                comment: "nfc unavailable"
            )
            return
        }
        let target = scannedMAC ?? selectedMAC
        let wasScanned = scannedMAC != nil
        wakeAttempts += 1
        let generation = UUID()
        wakeGeneration = generation
        isWakingWithNFC = true
        errorMessage = nil
        statusText = OttaiLocalizedString(
            "Hold the top of this iPhone against the sensor for a second.",
            comment: "nfc wake prompt"
        )
        OttaiDiagnosticEvent.record(.nfc, .started, attempt: wakeAttempts)
        OttaiNFCWaker.shared.begin { [weak self] result in
            Task { @MainActor in
                guard let self, self.wakeGeneration == generation else { return }
                self.isWakingWithNFC = false
                switch result {
                case .woke:
                    OttaiDiagnosticEvent.record(.nfc, .tagDetected, attempt: self.wakeAttempts)
                    self.statusText = OttaiLocalizedString("NFC signal sent. Looking for the sensor's Bluetooth signal…",
                        comment: "nfc wake searching"
                    )
                    self.scanForTarget(targetMAC: target, wasScanned: wasScanned)
                case .cancelled:
                    OttaiDiagnosticEvent.record(.nfc, .cancelled, attempt: self.wakeAttempts)
                    self.statusText = ""
                    self.errorMessage = OttaiLocalizedString("NFC was cancelled. You can try again.",
                        comment: "nfc wake cancelled"
                    )
                case .unavailable:
                    OttaiDiagnosticEvent.record(.nfc, .unavailable, attempt: self.wakeAttempts)
                    self.statusText = ""
                    self.errorMessage = OttaiLocalizedString(
                        "This iPhone can't read NFC tags.",
                        comment: "nfc unavailable"
                    )
                case .busy:
                    OttaiDiagnosticEvent.record(.nfc, .failed, attempt: self.wakeAttempts)
                    self.statusText = ""
                    self.errorMessage = OttaiLocalizedString("NFC is already waiting. Cancel it and try again.",
                        comment: "nfc busy"
                    )
                    // Supersede the old completion, then clear the stale reader
                    // so the next tap can start cleanly.
                    self.wakeGeneration = UUID()
                    OttaiNFCWaker.shared.cancelActive()
                case .failed:
                    OttaiDiagnosticEvent.record(.nfc, .failed, attempt: self.wakeAttempts)
                    self.statusText = ""
                    self.errorMessage = OttaiLocalizedString("NFC couldn't wake the sensor. Try again.",
                        comment: "nfc wake failed"
                    )
                }
            }
        }
    }
}

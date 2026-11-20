#if canImport(UIKit)
import Combine
import LocalAuthentication
import PrivacyKit
import SwiftUI
import UIKit

func privacyText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .module)
}

@MainActor public final class PrivacyLockController: NSObject, ObservableObject {
    public static let shared = PrivacyLockController()
    @Published public private(set) var isLocked = PrivacyVault.configured
    @Published private(set) var busy = false
    @Published var message: String?
    private var shield: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var pendingAction: (() -> Void)?
    private var context: LAContext?
    private var authenticationGeneration = 0

    public var configured: Bool { PrivacyVault.configured }
    var method: PrivacyLockMethod { PrivacyVault.method }
    var biometricsEnabled: Bool { UserDefaults.standard.bool(forKey: PrivacyPreference.biometricsKey) }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    public func attach(to scene: UIWindowScene) {
        guard shield?.windowScene !== scene else { updateShield(); return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .black
        window.rootViewController = UIHostingController(rootView: PrivacyShieldContents(controller: self))
        window.rootViewController?.view.accessibilityViewIsModal = true
        shield = window
        updateShield()
    }

    public func requireAuthentication(_ action: @escaping () -> Void) {
        guard configured else { action(); return }
        pendingAction = action
        isLocked = true
        message = nil
        updateShield()
    }

    public func lockNow() {
        guard configured else { return }
        pendingAction = nil
        isLocked = true
        updateShield()
    }

    @objc private func resignActive() {
        guard configured || PrivacyPreference.alertsEnabled else { return }
        if configured && !busy { isLocked = true }
        // Cover system snapshots synchronously, including sheets presented above the app root.
        showShield()
    }

    @objc private func enteredBackground() {
        guard configured else {
            if PrivacyPreference.alertsEnabled { showShield() }
            return
        }
        authenticationGeneration += 1
        context?.invalidate()
        pendingAction = nil
        isLocked = true
        showShield()
    }

    @objc private func becameActive() { updateShield() }

    private func updateShield() {
        if (configured && isLocked) || ((configured || PrivacyPreference.alertsEnabled) && UIApplication.shared.applicationState != .active) {
            showShield()
        } else if let shield, !shield.isHidden {
            shield.isHidden = true
            previousKeyWindow?.makeKey()
        }
    }

    private func showShield() {
        guard let shield else { return }
        if shield.isHidden {
            previousKeyWindow = shield.windowScene?.windows.first { $0.isKeyWindow && $0 !== shield }
            previousKeyWindow?.endEditing(true)
        }
        shield.isHidden = false
        if UIApplication.shared.applicationState == .active { shield.makeKey() }
    }

    private func completeUnlock() {
        guard UIApplication.shared.applicationState != .background else { return }
        isLocked = false
        message = nil
        updateShield()
        PrivacyPreference.record(stage: "authentication", outcome: "succeeded")
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    func unlock(secret: String) async {
        guard !busy else { return }
        let remaining = PrivacyVault.attempts.retryAfter.timeIntervalSinceNow
        guard remaining <= 0 else {
            message = String(format: privacyText("Try again in %d seconds."), Int(ceil(remaining)))
            return
        }
        busy = true
        let generation = authenticationGeneration
        defer { busy = false }
        do {
            let valid = try await Task.detached(priority: .userInitiated) { try PrivacyVault.verify(secret) }.value
            guard generation == authenticationGeneration else { return }
            if valid { completeUnlock() } else {
                message = privacyText("The code did not match. Try again.")
                PrivacyPreference.record(stage: "authentication", outcome: "failed")
            }
        } catch {
            message = privacyText("The viewing lock could not be read. Use device authentication to reset it.")
            PrivacyPreference.record(stage: "authentication", outcome: "failed")
        }
    }

    func authenticateWithDevice(reset: Bool = false) async {
        guard !busy, reset || biometricsEnabled else { return }
        busy = true
        let generation = authenticationGeneration
        let context = LAContext()
        self.context = context
        defer { busy = false; self.context = nil }
        do {
            let valid = try await context.evaluatePolicy(
                reset ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: privacyText(reset ? "Reset the viewing lock." : "Unlock private content.")
            )
            guard valid, generation == authenticationGeneration, UIApplication.shared.applicationState != .background else { return }
            if reset {
                try PrivacyVault.clear()
                PrivacyPreference.record(stage: "lock", outcome: "reset")
                PrivacyPreference.notifyChanged()
            }
            completeUnlock()
        } catch {
            message = privacyText("Authentication was not completed.")
        }
    }

    func configure(method: PrivacyLockMethod, secret: String) async throws {
        try await Task.detached(priority: .userInitiated) { try PrivacyVault.configure(method: method, secret: secret) }.value
        isLocked = UIApplication.shared.applicationState != .active
        updateShield()
        PrivacyPreference.record(stage: "lock", outcome: "enabled")
        PrivacyPreference.notifyChanged()
        objectWillChange.send()
    }

    func disable() {
        do {
            try PrivacyVault.clear()
            isLocked = false
            updateShield()
            PrivacyPreference.record(stage: "lock", outcome: "disabled")
            PrivacyPreference.notifyChanged()
            objectWillChange.send()
        } catch { message = privacyText("The viewing lock could not be saved.") }
    }
}

private struct ShieldAttachment: UIViewRepresentable {
    final class AttachmentView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { PrivacyLockController.shared.attach(to: scene) }
        }
    }
    func makeUIView(context: Context) -> UIView { AttachmentView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

public extension View {
    func privacyViewingShield() -> some View {
        background(ShieldAttachment().frame(width: 0, height: 0))
    }
}

private struct PrivacyShieldContents: View {
    @ObservedObject var controller: PrivacyLockController
    var body: some View {
        if controller.configured { PrivacyLockScreen(controller: controller) }
        else { Color.black.ignoresSafeArea() }
    }
}

struct PrivacyLockScreen: View {
    @ObservedObject var controller: PrivacyLockController
    @State private var secret = ""
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text(privacyText("Content locked")).font(.title2.weight(.semibold))
            Text(privacyText(controller.method == .pin ? "Enter your 4-digit PIN." : "Draw your unlock pattern."))
                .foregroundStyle(.secondary)
            PrivacySecretInput(method: controller.method, value: $secret) { value in
                Task { await controller.unlock(secret: value); secret = "" }
            }
            .disabled(controller.busy)
            if let message = controller.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if controller.biometricsEnabled {
                Button(privacyText("Use Face ID or Touch ID")) { Task { await controller.authenticateWithDevice() } }
                    .disabled(controller.busy)
            }
            Button(privacyText("Forgot PIN or pattern?")) { showResetConfirmation = true }
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .confirmationDialog(privacyText("Reset the viewing lock?"), isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button(privacyText("Verify with device passcode")) { Task { await controller.authenticateWithDevice(reset: true) } }
        } message: {
            Text(privacyText("After device-owner authentication, the app PIN or pattern will be removed. You can configure a new one in Privacy settings."))
        }
    }
}
#endif

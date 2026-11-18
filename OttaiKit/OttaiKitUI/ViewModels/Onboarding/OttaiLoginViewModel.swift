//
//  OttaiLoginViewModel.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Combine
import SwiftUI
import OttaiKit

@MainActor final class OttaiLoginViewModel: ObservableObject {
    @Published var email: String
    @Published var password: String = ""

    /// Mainland sign-in state. Untouched in `.email` mode.
    @Published var phone: String = ""
    @Published var smsCode: String = ""
    @Published var requestId: String?
    @Published var codeSent = false
    @Published var keepLoggedIn: Bool = true
    @Published var isBusy = false
    @Published var errorMessage: String?

    /// How this account signs in. The mainland service uses a phone number and
    /// an SMS code; the global service uses email and password. Decided from the
    /// manager type so both share one screen.
    enum Mode { case email, phone }

    let mode: Mode
    private let cgmManager: OttaiCGMManager
    private let onLoggedIn: () -> Void
    private let logger = OttaiLogger(category: "LoginViewModel")
    private var task: Task<Void, Never>?

    init(
        cgmManager: OttaiCGMManager,
        ottaiMode: Bool = false,
        allowDebugFeatures _: Bool = false,
        onLoggedIn: @escaping () -> Void
    ) {
        self.cgmManager = cgmManager
        self.onLoggedIn = onLoggedIn
        mode = (ottaiMode || cgmManager is OttaiCGMManager) ? .phone : .email
        email = cgmManager.account?.email ?? ""
    }

    var canSubmit: Bool {
        #if targetEnvironment(simulator)
            // Simulator builds may submit with empty fields to skip login entirely.
            return !isBusy
        #else
            if mode == .phone {
                return !isBusy && requestId != nil && !smsCode.isEmpty
            }
            return !isBusy && email.contains("@") && !password.isEmpty
        #endif
    }

    /// Whether the number is long enough to ask for a code.
    var canRequestCode: Bool {
        !isBusy && phone.trimmingCharacters(in: .whitespaces).count >= 11
    }

    func submit() {
        OttaiWireTrace.shared.append("> submit mode=\(mode) canSubmit=\(canSubmit) requestId=\(requestId == nil ? "nil" : "set") code=\(smsCode.count) busy=\(isBusy)")
        guard canSubmit else { return }
        errorMessage = nil
        #if targetEnvironment(simulator)
            // Empty fields on the simulator = skip login and proceed with no
            // session; anything else is a fake login (see CGMManager+Simulation).
            if email.isEmpty, password.isEmpty {
                logger.info("simulator skip-login")
            } else {
                cgmManager.startSimulatedAccount()
            }
            onLoggedIn()
        #else
            if mode == .phone { logInCn() } else { logIn() }
        #endif
    }

    /// `POST user/smsCode`; the returned `requestId` is what sign-in needs.
    func requestCode() {
        guard canRequestCode else { return }
        isBusy = true
        errorMessage = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let number = self.phone.trimmingCharacters(in: .whitespaces)
                let id = try await OttaiCnLoginProvider.requestCode(phone: number)
                OttaiWireTrace.shared.append("< requestId=\(id)")
                self.requestId = id
                self.codeSent = true
                self.isBusy = false
            } catch {
                self.isBusy = false
                self.logger.error("sms code request failed: \(error)")
                OttaiWireTrace.shared.append("!! smsCode \(error)")
                self.errorMessage = String(describing: error)
            }
        }
    }

    private func logInCn() {
        guard let requestId else {
            // Without a requestId the sign-in cannot even start; say so instead of
            // silently doing nothing (the button used to look dead).
            errorMessage = "No verification code was requested. Tap \"Send code\" first."
            return
        }
        isBusy = true
        errorMessage = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let number = self.phone.trimmingCharacters(in: .whitespaces)
            let code = self.smsCode.trimmingCharacters(in: .whitespaces)
            do {
                self.logger.info("sms login start phone=\(number) requestId=\(requestId)")
                OttaiWireTrace.shared.append("> smsLogin phone=\(number) code=\(code.count)ch")
                try await self.cgmManager.loginCn(phone: number, requestId: requestId, code: code)
                self.logger.info("sms login ok")
                OttaiWireTrace.shared.append("< smsLogin ok account=\(number)")
                self.isBusy = false
                self.smsCode = ""
                self.onLoggedIn()
            } catch {
                self.isBusy = false
                self.logger.error("sms login failed: \(error)")
                OttaiWireTrace.shared.append("!! smsLogin \(error)")
                self.errorMessage = String(describing: error)
            }
        }
    }

    private func logIn() {
        isBusy = true
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let password = self.password
            do {
                try await self.cgmManager.login(
                    email: email,
                    password: password,
                    keepLoggedIn: self.keepLoggedIn
                )
                self.isBusy = false
                self.password = "" // don't keep the password in memory past use
                self.onLoggedIn()
            } catch {
                self.isBusy = false
                self.logger.error("login failed: \(error)")

                // The login flow either throws LoginError or a transport error
                self.errorMessage = (error as? OttaiEnvelopedClient.LoginError)?.description
                    ?? String(
                        localized: "please check your connection and try again.",
                        comment: "login error: unexpected failure"
                    )
            }
        }
    }
}

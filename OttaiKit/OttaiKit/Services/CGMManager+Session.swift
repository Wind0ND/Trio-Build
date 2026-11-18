//
//  CGMManager+Session.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

actor OttaiSessionRecovery {
    private var inFlight: Task<OttaiBackend?, Never>?
    func run(_ work: @Sendable @escaping () async -> OttaiBackend?) async -> OttaiBackend? {
        if let inFlight { return await inFlight.value }
        let task = Task { await work() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

extension OttaiCGMManager {
    public enum AccountError: Error, CustomStringConvertible {
        case notLoggedIn
        public var description: String {
            switch self {
            case .notLoggedIn: return String(localized: "No Ottai account is logged in.", bundle: .ottaiKit)
            }
        }
    }

    public func login(email: String, password: String, keepLoggedIn: Bool = true) async throws {
        let provider = OttaiLoginCredentialProvider(
            email: email,
            password: password,
            template: type(of: self).backendTemplate
        )
        let backend = try await provider.backend()
        let session = OttaiAccountSession(
            email: email,
            backend: backend,
            password: keepLoggedIn ? password : nil
        )
        await MainActor.run { self.installSession(session) }
    }

    @MainActor func installSession(_ session: OttaiAccountSession) {
        OttaiKeychain.saveAccount(session, namespace: type(of: self).pluginIdentifier)
        account = session
        calibrationProvider = makeServerCalibrationProvider()
        telemetryService = makeTelemetryService()
        if state.accountLockedOutElsewhere {
            var updated = state
            updated.accountLockedOutElsewhere = false
            setState(updated)
        }
    }

    @discardableResult public func attemptSilentRelogin() async -> OttaiBackend? {
        guard let account, let password = account.password, !password.isEmpty else { return nil }
        let email = account.email
        // Read outside the sendable closure: `backendTemplate` is a class var, and a
        // subclass answers with a different host.
        let template = type(of: self).backendTemplate
        return await sessionRecovery.run {
            do {
                let provider = OttaiLoginCredentialProvider(
                    email: email,
                    password: password,
                    template: template
                )
                let backend = try await provider.backend()
                let session = OttaiAccountSession(email: email, backend: backend, password: password)
                await MainActor.run { self.installSession(session) }
                self.logger.info("silent re-login succeeded for \(OttaiRedact.email(email))")
                return backend
            } catch {
                self.logger.error("silent re-login failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    public func logOut() {
        OttaiKeychain.deleteAccount(namespace: type(of: self).pluginIdentifier)
        account = nil
        if calibrationProvider is OttaiServerCalibrationProvider {
            calibrationProvider = nil
        }
        telemetryService = nil
    }

    public func configureForAccount(sensorKit: OttaiBLE) throws {
        guard let provider = makeServerCalibrationProvider() else { throw AccountError.notLoggedIn }
        configure(sensorKit: sensorKit, calibrationProvider: provider)
        telemetryService = makeTelemetryService()
    }

    func makeSessionRotationHandler() -> @Sendable(OttaiCredentials, String?) -> Void {
        { [weak self] rotated, gsk in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let current = self.account else { return }
                let updated = current.withRotatedCredentials(rotated, glucoseSecretKey: gsk)
                guard updated != current else { return }
                OttaiKeychain.saveAccount(updated, namespace: type(of: self).pluginIdentifier)
                self.account = updated
            }
        }
    }

    func makeAccountLockoutHandler() -> @Sendable(Bool) -> Void {
        { [weak self] lockedOut in
            Task { @MainActor in
                guard let self, self.state.accountLockedOutElsewhere != lockedOut else { return }
                var updated = self.state
                updated.accountLockedOutElsewhere = lockedOut
                self.setState(updated)
                if lockedOut {
                    // The server has revoked this session, and the Keychain entry
                    // survives CGM deletion and reinstall. Leaving it would restore
                    // a dead login on the next add. The in-memory account stays for
                    // display until the user re-authenticates.
                    OttaiKeychain.deleteAccount(namespace: type(of: self).pluginIdentifier)
                }
            }
        }
    }

    func makeSessionRecoveryHandler() -> @Sendable() async -> OttaiBackend? {
        { [weak self] in
            guard let self else { return nil }
            return await self.attemptSilentRelogin()
        }
    }

    private func makeServerCalibrationProvider() -> OttaiServerCalibrationProvider? {
        guard let account else { return nil }
        return OttaiServerCalibrationProvider(
            backend: account.backend(template: type(of: self).backendTemplate),
            onSessionRotated: makeSessionRotationHandler(),
            recoverSession: makeSessionRecoveryHandler(),
            onAccountLockoutChanged: makeAccountLockoutHandler()
        )
    }

    func makeServerDeviceBinder() -> OttaiServerDeviceBinder? {
        guard let account else { return nil }
        return OttaiServerDeviceBinder(
            backend: account.backend(template: type(of: self).backendTemplate),
            onSessionRotated: makeSessionRotationHandler(),
            recoverSession: makeSessionRecoveryHandler(),
            onAccountLockoutChanged: makeAccountLockoutHandler()
        )
    }

    private func makeTelemetryService() -> OttaiTelemetryService? {
        guard let account else { return nil }
        return OttaiTelemetryService(
            client: OttaiEnvelopedClient(backend: account.backend(template: type(of: self).backendTemplate)),
            restoredQueue: state.telemetryQueue,
            tier: { [weak self] in self?.state.telemetryTier ?? .minimal },
            persistQueue: { [weak self] records in
                Task { @MainActor in
                    guard let self else { return }
                    var updated = self.state
                    updated.telemetryQueue = records
                    self.setState(updated)
                }
            },
            sensorContext: { [weak self] in
                guard let self, let record = self.state.sensors.current(),
                      let activatedAt = record.activatedAt else { return nil }
                return OttaiTelemetryService.SensorContext(
                    serverDeviceId: record.serverDeviceId,
                    embeddedSoftVersion: record.deviceInfo.deviceVersion,
                    activatedAtMs: Int64(activatedAt.timeIntervalSince1970 * 1000),
                    mac: record.mac
                )
            },

            accountContext: { [weak self] in
                guard let self, let account = self.account else { return nil }
                let backend = account.backend(template: type(of: self).backendTemplate)
                guard let userId = account.userId ?? backend.userId else { return nil }
                return OttaiTelemetryService.AccountContext(userId: userId, appName: backend.appName)
            },
            onSessionRotated: makeSessionRotationHandler(),
            persistServerDeviceId: { [weak self] id in
                Task { @MainActor in
                    guard let self else { return }
                    var updated = self.state
                    updated.sensors.setServerDeviceId(id)
                    self.setState(updated)
                }
            },
            onAccountLockoutChanged: makeAccountLockoutHandler()
        )
    }
}

//
//  CGMManager+BoundSensor.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public extension OttaiCGMManager {
    enum BoundSensorError: Error, CustomStringConvertible, LocalizedError {
        case notConfigured
        case previouslyEnded
        case pastWear
        case unsupportedFirmware(String)

        public var description: String {
            switch self {
            case .notConfigured:
                return LocalizedString("Log in to Ottai first.", comment: "bound sensor: not logged in")
            case .previouslyEnded:
                return String(
                    format: LocalizedString(
                        "This sensor was already ended in %1$@ and can't be used again.",
                        comment: "bound sensor: retired (1: appName)"
                    ),
                    Bundle.main.ottaiHostAppName
                )
            case .pastWear:
                return LocalizedString(
                    "This sensor's wear period has ended.",
                    comment: "bound sensor: expired"
                )
            case let .unsupportedFirmware(version):
                return String(
                    format: LocalizedString(
                        "This sensor's firmware (%1$@) isn't supported yet. Keep using it with the official Ottai app.",
                        comment: "bound sensor: unsupported firmware (1: firmware version)"
                    ),
                    version
                )
            }
        }

        public var errorDescription: String? { description }
    }

    /// Whether a bound sensor may be taken over, or why not.
    func adoptionBlocker(for sensor: OttaiBoundSensor) -> BoundSensorError? {
        let retired = state.sensors.history().contains { $0.mac == sensor.mac && $0.retiredAt != nil }
        if retired { return .previouslyEnded }
        if sensor.isPastWear { return .pastWear }
        // The server's version string; an empty one is checked on first connect instead.
        let version = sensor.deviceInfo.deviceVersion
        if !version.isEmpty,
           !OttaiFrameParser.isVerified(parseVersion: OttaiFrameParser.parseVersion(forDeviceVersion: version))
        {
            return .unsupportedFirmware(version)
        }
        return nil
    }

    /// Onboarding-only handle on the account lookup, so the pairing screen can
    /// show what the CN service answers without touching logs on the phone.
    public func diagnosticsLookup() -> OttaiBoundSensorLookup? { makeBoundSensorLookup() }

    func makeBoundSensorLookup() -> OttaiBoundSensorLookup? {
        guard let account else { return nil }
        return OttaiBoundSensorLookup(
            backend: account.backend(template: type(of: self).backendTemplate),
            onSessionRotated: makeSessionRotationHandler(),
            recoverSession: makeSessionRecoveryHandler(),
            onAccountLockoutChanged: makeAccountLockoutHandler()
        )
    }

    /// The host app has never had a GATT link to the active sensor. Activation records
    /// the peripheral, so this only holds for a taken-over sensor that hasn't
    /// connected yet.
    internal var hasNeverConnected: Bool {
        state.mac != nil && state.sensors.current()?.peripheralID == nil
    }

    /// A taken-over sensor the host app can't reach. The sensor is a GATT server that
    /// serves one central at a time (there is no bonding), so the usual cause
    /// is the official Ottai app still holding the connection.
    var needsOfficialAppClosed: Bool {
        hasNeverConnected && !hasLiveLink && firstConnectionFailed
    }

    /// The sensor bound to the logged-in account, if any.
    func lookUpBoundSensor() async throws -> OttaiBoundSensor? {
        #if targetEnvironment(simulator)
            // Fake login: a fake bound sensor. Skipped login: nothing bound.
            if simulatedAccount || account == nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return simulatedBoundSensor()
            }
        #endif
        guard let lookup = makeBoundSensorLookup() else { throw BoundSensorError.notConfigured }
        return try await lookup.boundSensor()
    }

    /// Takes over a sensor that is already activated and bound: no activation
    /// writes and no bind, just persist the record and connect the way a
    /// reconnect does.
    @MainActor func adoptBoundSensor(_ sensor: OttaiBoundSensor) throws {
        if let blocker = adoptionBlocker(for: sensor) { throw blocker }
        #if targetEnvironment(simulator)
            configureForSimulationIfNeeded()
        #endif
        guard sensorKit != nil, calibrationProvider != nil else { throw BoundSensorError.notConfigured }

        logger.info(
            "adopting bound sensor mac=\(OttaiRedact.mac(sensor.mac)) fw=\(sensor.deviceInfo.deviceVersion)"
        )
        cancelReconnect()
        monitor?.disconnect()
        monitor = nil
        firstConnectionFailed = false

        var newState = state
        newState.resetSensorSession()
        plausibilityGuard = OttaiPlausibilityGuard()
        newState.sensors.adopt(
            sensor.deviceInfo, keyGroup: sensor.keyGroup,
            peripheralID: nil, activatedAt: sensor.activatedAt
        )
        setState(newState)
        emitSensorStartEvent(for: newState)
        scheduleReconnect()
    }
}

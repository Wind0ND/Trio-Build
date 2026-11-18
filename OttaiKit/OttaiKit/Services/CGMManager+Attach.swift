//
//  CGMManager+Attach.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public extension OttaiCGMManager {
    enum AttachError: Error, CustomStringConvertible {
        case notConfigured
        case service(OttaiPairingService.Failure)
        public var description: String {
            switch self {
            case .notConfigured: return "Sensor stack not configured (no sensor kit / calibration provider)."
            case let .service(f): return f.description
            }
        }
    }

    func configure(sensorKit: OttaiBLE, calibrationProvider: CalibrationProvider) {
        self.sensorKit = sensorKit
        self.calibrationProvider = calibrationProvider
        if state.mac != nil, !hasLiveLink {
            Task { @MainActor in self.scheduleReconnect() }
        }
    }

    internal func wireStackForRestoreIfNeeded() {
        guard sensorKit == nil else { return }
        if (try? configureForAccount(sensorKit: OttaiBLE())) != nil { return }
        if state.sensors.current() != nil {
            configure(sensorKit: OttaiBLE(), calibrationProvider: OttaiUnavailableCalibrationProvider())
        }
    }

    func discoverSensorCandidates() async throws -> [OttaiSensorCandidate] {
        #if targetEnvironment(simulator)
            return await simulatedCandidates()
        #else
            guard let sensorKit else { throw AttachError.notConfigured }
            return try await sensorKit.discoverSensorCandidates()
        #endif
    }

    /// Exact-MAC discovery used by the NFC wake flow when a target is already
    /// chosen. Simulator candidates are filtered the same way the real scanner
    /// filters its advertisements.
    func discoverSensor(mac: String) async throws -> OttaiSensorCandidate? {
        #if targetEnvironment(simulator)
            let target = OttaiWakeTargetMatcher.normalized(mac)
            return await simulatedCandidates().first {
                OttaiWakeTargetMatcher.normalized($0.mac) == target
            }
        #else
            guard let sensorKit else { throw AttachError.notConfigured }
            return try await sensorKit.discoverSensor(mac: mac)
        #endif
    }
}

private struct OttaiUnavailableCalibrationProvider: CalibrationProvider {
    func validate(mac _: String) async throws -> OttaiSensorValidation {
        throw OttaiCGMManager.AccountError.notLoggedIn
    }

    func authorizeActivation(mac _: String, authDev _: Data, authFlag _: Data) async throws -> OttaiRemoteActivation {
        throw OttaiCGMManager.AccountError.notLoggedIn
    }
}

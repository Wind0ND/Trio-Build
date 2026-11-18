//
//  OttaiBLE.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public final class OttaiBLE: @unchecked Sendable {
    private let logger = OttaiLogger(category: "SensorKit")
    private let central = OttaiBLECentral.shared
    private let frameParsing: OttaiFrameParsing
    private let overrideMAC: String?
    private let discoveryScanTimeout: TimeInterval
    private let scanTimeout: TimeInterval
    private let reconnectScanTimeout: TimeInterval
    private let aes = AESECB()

    public init(
        frameParsing: OttaiFrameParsing = OttaiV17FrameParsing(fallback: OttaiV16FrameParsing()),
        overrideMAC: String? = nil,
        discoveryScanTimeout: TimeInterval = 30,
        scanTimeout: TimeInterval = 20,
        reconnectScanTimeout: TimeInterval = 180
    ) {
        self.frameParsing = frameParsing
        self.overrideMAC = overrideMAC
        self.discoveryScanTimeout = discoveryScanTimeout
        self.scanTimeout = scanTimeout
        self.reconnectScanTimeout = reconnectScanTimeout
    }

    public func readMAC() async throws -> OttaiSensorIdentity {
        if let overrideMAC, !overrideMAC.isEmpty {
            return OttaiSensorIdentity(mac: overrideMAC.uppercased())
        }

        let found = try await central.discoverSensors(scanTimeout: discoveryScanTimeout)
        guard let strongest = found.first else {
            throw OttaiPairingService.Failure.bleNoSensorDiscovered
        }
        if found.count > 1 {
            logger.info(
                "multiple sensors in range; picking strongest \(OttaiRedact.mac(strongest.mac)) "
                    + "(rssi \(strongest.rssi)) of \(found.count)"
            )
        }
        return OttaiSensorIdentity(mac: strongest.mac)
    }

    public func discoverSensorCandidates() async throws -> [OttaiSensorCandidate] {
        if let overrideMAC, !overrideMAC.isEmpty {
            return [OttaiSensorCandidate(mac: overrideMAC.uppercased())]
        }

        return try await central.discoverSensors(scanTimeout: discoveryScanTimeout)
            .map { OttaiSensorCandidate(mac: $0.mac, rssi: $0.rssi) }
    }

    /// Exact-MAC discovery for a target already chosen by QR or the picker.
    /// This waits for that advertiser (or the normal timeout) rather than
    /// returning after the generic discovery settle window.
    public func discoverSensor(mac: String) async throws -> OttaiSensorCandidate? {
        if let overrideMAC, !overrideMAC.isEmpty {
            guard OttaiWakeTargetMatcher.normalized(overrideMAC) == OttaiWakeTargetMatcher.normalized(mac) else {
                return nil
            }
            return OttaiSensorCandidate(mac: overrideMAC.uppercased())
        }
        return try await central.discoverSensor(mac: mac, scanTimeout: discoveryScanTimeout)
            .map { OttaiSensorCandidate(mac: $0.mac, rssi: $0.rssi) }
    }

    public func connectAndAuthenticate(
        identity: OttaiSensorIdentity,
        keyGroup: OttaiKeyGroup?,
        expectedPeripheralID: UUID?
    ) async throws -> OttaiSensorSession {
        guard let keyGroup else { throw OttaiPairingService.Failure.noKeyGroup }
        let s = try await connectAndAuth(
            mac: identity.mac,
            keyGroup: keyGroup,
            expectedPeripheralID: expectedPeripheralID,
            scanTimeout: reconnectScanTimeout
        )
        try refuseUnverifiedFirmware(s)
        return makeSession(s, keyGroup: keyGroup, cmdState: s.cmdState)
    }

    /// What a remote activation left behind. The link is closed afterwards:
    /// the server held the session key for it, so nothing can be read on it.
    public struct RemoteActivationOutcome: Sendable {
        public let peripheralID: UUID
        public let firmwareVersion: String
        /// False when the cmd gate found the sensor already activated and no
        /// activation frame was written.
        public let didActivate: Bool
    }

    /// Activates a factory sensor the way the official app now does: the
    /// sensor's auth challenge (`authDev` + `authFlag`) is answered by the
    /// server through `authorize`, which also returns the encrypted activation
    /// frames for this connection. The phone never holds the key group or the
    /// session key here; the key group arrives with the bind afterwards, and
    /// streaming starts on a fresh, locally authenticated connection.
    public func activateRemotely(
        identity: OttaiSensorIdentity,
        authorize: @Sendable (_ authDev: Data, _ authFlag: Data) async throws -> OttaiRemoteActivation
    ) async throws -> RemoteActivationOutcome {
        let peripheral = try await connect(mac: identity.mac, expectedPeripheralID: nil, scanTimeout: scanTimeout)
        defer { peripheral.disconnect() }

        let firmware = await readFirmware(peripheral)
        try refuseUnverifiedFirmware(peripheral: peripheral, firmwareVersion: firmware.version, parseVersion: firmware.parseVersion)

        let authDev: Data
        let authFlag: Data
        do {
            authDev = try await peripheral.read(OttaiGATT.authDev)
            authFlag = try await peripheral.read(OttaiGATT.authFlag)
        } catch {
            throw OttaiPairingService.Failure.droppedAfterConnect(error.localizedDescription)
        }
        logger.debug("remote auth: challenge read (authDev \(authDev.count) B, authFlag \(authFlag.count) B)")
        // An all-zero signature is not a real challenge yet; don't spend a server round-trip on it.
        guard authFlag.contains(where: { $0 != 0 }) else {
            throw OttaiPairingService.Failure.droppedAfterConnect("sensor presented an empty auth challenge")
        }

        let activation = try await authorize(authDev, authFlag)

        do {
            try await peripheral.write(activation.authHost, to: OttaiGATT.authHost, withResponse: true)
            try await peripheral.write(activation.authFlag, to: OttaiGATT.authFlag, withResponse: true)
        } catch {
            throw OttaiPairingService.Failure.droppedAfterConnect(error.localizedDescription)
        }
        logger.debug("remote auth: server answer written")

        var didActivate = false
        do {
            logger.info("activating sensor mac=\(OttaiRedact.mac(identity.mac)) fw=\"\(firmware.version)\"")
            try await OttaiActivationSequence.run(transport: peripheral, activation: activation)
            didActivate = true
            logger.info("activated sensor mac=\(OttaiRedact.mac(identity.mac))")
        } catch let OttaiActivationSequence.ActivationError.alreadyActive(state) {
            logger.info("sensor already activated (cmd-state \(state)); skipping writes mac=\(OttaiRedact.mac(identity.mac))")
        }
        return RemoteActivationOutcome(
            peripheralID: peripheral.peripheralID,
            firmwareVersion: firmware.version,
            didActivate: didActivate
        )
    }

    public func rawChannels(from frame: OttaiDecryptedFrame) throws -> OttaiGlucoseDecoder.RawChannels {
        try OttaiFrameParser.rawChannels(from: frame, using: frameParsing)
    }

    private struct AuthedLink {
        let peripheral: OttaiBLEPeripheral
        let sessionKey: Data
        let firmwareVersion: String
        let parseVersion: String
        /// The cmd characteristic's lifecycle state at connect, or nil if the read failed.
        let cmdState: Int?
    }

    // 0: starting, 1: self-test, 2: unactivated, 3: healthy, 4: faulty/obsolete
    static let healthyCmdState = 3

    private func connect(mac: String, expectedPeripheralID: UUID?, scanTimeout: TimeInterval) async throws -> OttaiBLEPeripheral {
        do {
            return try await central.scanAndConnect(
                mac: mac, expectedPeripheralID: expectedPeripheralID, scanTimeout: scanTimeout
            )
        } catch let OttaiBLECentral.BLEError.disconnected(reason) {
            throw OttaiPairingService.Failure.droppedAfterConnect(reason)
        }
    }

    private func readFirmware(_ peripheral: OttaiBLEPeripheral) async -> (version: String, parseVersion: String) {
        let versionData = (try? await peripheral.read(OttaiGATT.softVersion)) ?? Data()
        let versionStr = String(data: versionData, encoding: .utf8) ?? ""
        let parseVersion = OttaiFrameParser.parseVersion(forDeviceVersion: versionStr)
        if versionStr.contains("V1.8.") || versionStr.contains("V2.0.") {
            logger.info("firmware \"\(versionStr)\" is decoded as V1.7 per the vendor profile; first hardware sighting")
        }
        return (versionStr, parseVersion)
    }

    private func connectAndAuth(
        mac: String,
        keyGroup: OttaiKeyGroup,
        expectedPeripheralID: UUID?,
        scanTimeout: TimeInterval
    ) async throws -> AuthedLink {
        let peripheral = try await connect(mac: mac, expectedPeripheralID: expectedPeripheralID, scanTimeout: scanTimeout)

        let sessionKey: Data
        do {
            sessionKey = try await OttaiBLEAuthV2.authenticate(
                transport: peripheral, mac: mac, keyGroup: keyGroup
            )
        } catch {
            throw OttaiPairingService.Failure.droppedAfterConnect(error.localizedDescription)
        }

        let firmware = await readFirmware(peripheral)

        do {
            try await peripheral.write(
                OttaiActivationFrame.defaultBleIntervalFrame(),
                to: OttaiGATT.ctlDevice,
                withResponse: false
            )
            logger.debug("wrote BLE interval setting")
        } catch {
            logger.debug("BLE interval setting write failed: \(error.localizedDescription)")
        }

        let cmdState = (try? await peripheral.read(OttaiGATT.cmd)).flatMap(\.first).map(Int.init)
        if let cmdState, cmdState > Self.healthyCmdState {
            logger
                .error("sensor cmd-state \(cmdState) (> \(Self.healthyCmdState)): device state obsolete (sensor needs replacing)")
        }
        logger
            .info(
                "authenticated. mac=\(OttaiRedact.mac(mac)) fw=\"\(firmware.version)\" parseVersion=\(firmware.parseVersion) cmdState=\(cmdState.map(String.init) ?? "unread")"
            )
        return AuthedLink(
            peripheral: peripheral,
            sessionKey: sessionKey,
            firmwareVersion: firmware.version,
            parseVersion: firmware.parseVersion,
            cmdState: cmdState
        )
    }

    /// Drops the link to a sensor whose readings can't be decoded, before
    /// anything is written to it.
    private func refuseUnverifiedFirmware(_ link: AuthedLink) throws {
        try refuseUnverifiedFirmware(
            peripheral: link.peripheral, firmwareVersion: link.firmwareVersion, parseVersion: link.parseVersion
        )
    }

    private func refuseUnverifiedFirmware(peripheral: OttaiBLEPeripheral, firmwareVersion: String, parseVersion: String) throws {
        guard !OttaiFrameParser.isVerified(parseVersion: parseVersion) else { return }
        logger.error("refusing sensor: firmware \"\(firmwareVersion)\" has no verified glucose decode")
        peripheral.disconnect()
        throw OttaiPairingService.Failure.unsupportedFirmware(firmwareVersion)
    }

    private func makeSession(_ link: AuthedLink, keyGroup: OttaiKeyGroup, cmdState: Int?) -> OttaiSensorSession {
        OttaiSensorSession(
            transport: link.peripheral, keyGroup: keyGroup, sessionKey: link.sessionKey,
            parseVersion: link.parseVersion, aes: aes,
            reportedCmdState: cmdState
        )
    }
}

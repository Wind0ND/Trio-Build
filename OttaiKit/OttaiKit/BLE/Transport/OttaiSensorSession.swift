//
//  OttaiSensorSession.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public final class OttaiSensorSession: @unchecked Sendable {
    public let peripheralID: UUID
    public let keyGroup: OttaiKeyGroup

    private let transport: OttaiGATTTransport
    private let sessionKey: Data
    private let parseVersion: String
    private let recLen: Int
    private let aes: AESECB

    /// The cmd characteristic's lifecycle state read at connect (0 initialize,
    /// 1 self-test, 2 unactivated, 3 activated/healthy, 4+ dead), or nil if the
    /// read failed. Exposed as the raw value (not pre-filtered to just the
    /// fault case) so callers above the BLE layer, which know whether this
    /// sensor was already activated, can decide what a reported state below
    /// 3 means, not just whether it's above the obsolete threshold.
    public let reportedCmdState: Int?

    private let logger = OttaiLogger(category: "SensorSession")

    init(
        transport: OttaiGATTTransport,
        keyGroup: OttaiKeyGroup,
        sessionKey: Data,
        parseVersion: String,
        aes: AESECB,
        reportedCmdState: Int? = nil
    ) {
        self.transport = transport
        peripheralID = transport.peripheralID
        self.keyGroup = keyGroup
        self.sessionKey = sessionKey
        self.reportedCmdState = reportedCmdState
        self.parseVersion = parseVersion
        recLen = OttaiFrameCipher.recordLength(parseVersion: parseVersion)
        self.aes = aes
    }

    public func glucoseFrames() -> AsyncStream<OttaiDecryptedFrame> {
        AsyncStream { continuation in
            let live = transport.notifications(for: OttaiGATT.newGlucose)
            let history = transport.notifications(for: OttaiGATT.glucoseRecord)
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await data in live { self.emit(data, isHistorical: false, into: continuation) } }
                    group.addTask { for await data in history { self.emit(data, isHistorical: true, into: continuation) } }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func emit(
        _ notify: Data,
        isHistorical: Bool,
        into continuation: AsyncStream<OttaiDecryptedFrame>.Continuation
    ) {
        do {
            let org = try OttaiFrameCipher.decryptOrg(notify: notify, sessionKey: sessionKey, aes: aes)
            let records = try OttaiFrameCipher.split(org: org, recLen: recLen)
            let now = Date()
            for r in records {
                let frame = OttaiDecryptedFrame(
                    plaintext: r.framed, sequence: r.index, parseVersion: parseVersion,
                    receivedAt: now, isHistorical: isHistorical
                )
                continuation.yield(frame)
            }
            if isHistorical, let info = try? OttaiFrameCipher.packetInfo(org: org) {
                batchContinuation?.yield(.packetReceived(
                    startIndex: info.startIndex, recordCount: records.count,
                    surplusPackage: info.surplusPackage
                ))
                if info.isBatchComplete { batchContinuation?.yield(.batchComplete) }
            }
        } catch {
            logger.warning("frame decode skipped: \(error.localizedDescription) notify=\(OttaiDiagnostics.hex(notify))")
        }
    }

    private var batchContinuation: AsyncStream<OttaiHistoricalBatchStatus>.Continuation?

    public func historicalBatchEvents() -> AsyncStream<OttaiHistoricalBatchStatus> {
        AsyncStream { continuation in
            self.batchContinuation = continuation
        }
    }

    public func requestHistorical(fromIndex: UInt16, count: UInt16) async throws {
        var payload = Data()
        payload.append(UInt8(fromIndex & 0xFF))
        payload.append(UInt8(fromIndex >> 8))
        payload.append(UInt8(count & 0xFF))
        payload.append(UInt8(count >> 8))
        try await transport.write(payload, to: OttaiGATT.requestByCount, withResponse: true)
    }

    public func faultEvents() -> AsyncStream<OttaiSensorFault> {
        AsyncStream { continuation in
            if let state = reportedCmdState, state > OttaiBLE.healthyCmdState {
                logger.error("device state obsolete (cmd-state \(state)); sensor must be replaced")
                continuation.yield(OttaiSensorFault(
                    kind: .deviceStateObsolete(state: state),
                    raw: Data([UInt8(clamping: state)]),
                    receivedAt: Date()
                ))
            }
            let errors = transport.notifications(for: OttaiGATT.errorInfo)
            let task = Task {
                for await data in errors {
                    let hex = data.map { String(format: "%02x", $0) }.joined()
                    if let frame = OttaiNotifyInfo.decode(data) {
                        self.logger.info("\(frame.logDescription)")
                    } else {
                        self.logger.info("errorInfo (undecodable, \(data.count) B): \(hex)")
                    }

                    // Mirrors the official app's `cgm_notify_info` telemetry event,
                    // fired for every errorInfo notify, not just the decodable ones.
                    self.notifyInfoContinuation?.yield(hex)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var notifyInfoContinuation: AsyncStream<String>.Continuation?

    public func notifyInfoEvents() -> AsyncStream<String> {
        AsyncStream { continuation in
            self.notifyInfoContinuation = continuation
        }
    }

    public func disconnect() { transport.disconnect() }

    public func endSensor() async throws {
        logger.info("writing end-of-sensor command to ctlDevice")
        try await transport.write(
            OttaiActivationFrame.endSensorFrame(),
            to: OttaiGATT.ctlDevice,
            withResponse: true
        )
    }
}

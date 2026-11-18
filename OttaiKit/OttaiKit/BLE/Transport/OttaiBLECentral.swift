//
//  OttaiBLECentral.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public final class OttaiBLECentral: NSObject, @unchecked Sendable {
    public enum BLEError: Error, CustomStringConvertible {
        case bluetoothUnavailable(CBManagerState)
        case connectFailed(String)
        case disconnected(String)
        case busy
        public var description: String {
            switch self {
            case let .bluetoothUnavailable(s): return "Bluetooth unavailable (state \(s.rawValue))."
            case let .connectFailed(m): return "BLE connect failed: \(m)"
            case let .disconnected(m): return "BLE disconnected: \(m)"
            case .busy: return "Bluetooth is busy with another sensor operation. Try again in a moment."
            }
        }
    }

    public struct DiscoveredSensor: Equatable, Sendable {
        public let mac: String
        public let rssi: Int
        public let peripheralID: UUID
        public init(mac: String, rssi: Int, peripheralID: UUID) {
            self.mac = mac
            self.rssi = rssi
            self.peripheralID = peripheralID
        }
    }

    private let logger = OttaiLogger(category: "OttaiBLECentral")
    private let queue = DispatchQueue(label: "org.loopkit.OttaiKit.ble")
    private lazy var manager = CBCentralManager(
        delegate: self, queue: queue,
        options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
    )

    public static let restorationIdentifier = "org.loopkit.OttaiKit.central"

    public static let shared = OttaiBLECentral()

    private var powerOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: PendingConnect?
    private var pendingDiscovery: PendingDiscovery?
    private weak var live: OttaiBLEPeripheral?
    private var restoredPeripherals: [CBPeripheral] = []

    private struct PendingConnect {
        let targetMAC: String
        let expectedPeripheralID: UUID?
        let continuation: CheckedContinuation<OttaiBLEPeripheral, Error>
        var wrapper: OttaiBLEPeripheral?
        var standing: CBPeripheral?
        var finished = false
        let timeout: DispatchWorkItem
    }

    private struct PendingDiscovery {
        let continuation: CheckedContinuation<[DiscoveredSensor], Error>
        var found: [UUID: DiscoveredSensor] = [:]
        let settleWindow: TimeInterval
        let targetMAC: String?
        var settle: DispatchWorkItem?
        let timeout: DispatchWorkItem
        var finished = false
    }

    override private init() {
        super.init()
        _ = manager // kick off state updates (iOS delivers willRestoreState here)
    }

    public func scanAndConnect(
        mac: String,
        expectedPeripheralID: UUID?,
        scanTimeout: TimeInterval = 20
    ) async throws -> OttaiBLEPeripheral {
        try await ensurePoweredOn()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    // A second caller must not overwrite `pending`: the replaced
                    // entry's timeout would stay scheduled and later fire
                    // `failPending`, killing the NEW connection.
                    guard self.pending == nil, self.pendingDiscovery == nil else {
                        cont.resume(throwing: BLEError.busy)
                        return
                    }
                    let timeoutItem = DispatchWorkItem { [weak self] in
                        self?.failPending(OttaiPairingService.Failure.sensorDormantNeedsNFC)
                    }
                    self.pending = PendingConnect(
                        targetMAC: mac.uppercased(),
                        expectedPeripheralID: expectedPeripheralID,
                        continuation: cont,
                        timeout: timeoutItem
                    )
                    self.queue.asyncAfter(deadline: .now() + scanTimeout, execute: timeoutItem)
                    if let id = expectedPeripheralID,
                       let restored = self.restoredPeripherals.first(where: { $0.identifier == id })
                    {
                        self.restoredPeripherals.removeAll { $0.identifier == id }
                        self.attachRestored(restored)
                        return
                    }
                    self.manager.scanForPeripherals(
                        withServices: [OttaiGATT.cgmService],
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                    self.logger.debug("scanning for \(OttaiRedact.mac(mac))")
                    if let id = expectedPeripheralID {
                        let known = self.manager.retrievePeripherals(withIdentifiers: [id])
                        if let standing = known.first {
                            self.attachStanding(standing)
                        } else {
                            self.logger.debug("no retrievable peripheral for \(id.uuidString); scan only")
                        }
                    }
                }
            }
        } onCancel: {
            // Task cancellation (e.g. cancelReconnect on delete) must reach the
            // central, otherwise the pending entry and its timeout outlive the
            // caller and later abort an unrelated connect.
            self.queue.async { self.failPending(CancellationError()) }
        }
    }

    public func discoverSensors(
        scanTimeout: TimeInterval = 20,
        settleWindow: TimeInterval = 1.5
    ) async throws -> [DiscoveredSensor] {
        try await ensurePoweredOn()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.pending == nil, self.pendingDiscovery == nil else {
                    cont.resume(throwing: BLEError.busy)
                    return
                }
                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.finishDiscovery()
                }
                self.pendingDiscovery = PendingDiscovery(
                    continuation: cont, settleWindow: settleWindow, targetMAC: nil, timeout: timeoutItem
                )
                self.queue.asyncAfter(deadline: .now() + scanTimeout, execute: timeoutItem)
                // Duplicates refresh RSSI so `found` keeps the strongest sighting.
                self.manager.scanForPeripherals(
                    withServices: [OttaiGATT.cgmService],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
                self.logger.debug("discovering sensors (up to \(Int(scanTimeout)) s)")
            }
        }
    }

    /// Wait for one exact advertised MAC. Unlike `discoverSensors`, this does
    /// not stop at the generic settle window after hearing some other sensor;
    /// it returns as soon as the target is seen or when the normal scan timeout
    /// expires. No wire/protocol behavior changes.
    public func discoverSensor(mac: String, scanTimeout: TimeInterval = 20) async throws -> DiscoveredSensor? {
        try await ensurePoweredOn()
        let found = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[DiscoveredSensor], Error>) in
            queue.async {
                guard self.pending == nil, self.pendingDiscovery == nil else {
                    cont.resume(throwing: BLEError.busy)
                    return
                }
                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.finishDiscovery()
                }
                self.pendingDiscovery = PendingDiscovery(
                    continuation: cont,
                    settleWindow: 0,
                    targetMAC: mac.uppercased(),
                    timeout: timeoutItem
                )
                self.queue.asyncAfter(deadline: .now() + scanTimeout, execute: timeoutItem)
                self.manager.scanForPeripherals(
                    withServices: [OttaiGATT.cgmService],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
                self.logger.debug("discovering target sensor \(OttaiRedact.mac(mac)) (up to \(Int(scanTimeout)) s)")
            }
        }
        return found.first
    }

    public static func advertisedMAC(fromManufacturerData data: Data?) -> String? {
        guard let data, data.count > 2 else { return nil }
        return data.dropFirst(2).map { String(format: "%02X", $0) }.joined()
    }

    private func ensurePoweredOn() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                switch self.manager.state {
                case .poweredOn: cont.resume()
                case .resetting,
                     .unknown: self.powerOnWaiters.append(cont)
                default: cont.resume(throwing: BLEError.bluetoothUnavailable(self.manager.state))
                }
            }
        }
    }

    private func attachRestored(_ peripheral: CBPeripheral) {
        guard pending?.finished == false else { return }
        logger.info("using state-restored peripheral \(peripheral.identifier.uuidString) (state \(peripheral.state.rawValue))")
        let wrapper = OttaiBLEPeripheral(peripheral: peripheral, manager: manager, queue: queue)
        pending?.wrapper = wrapper
        if peripheral.state == .connected {
            wrapper.beginDiscovery { [weak self] result in
                switch result {
                case .success: self?.finishPending(wrapper)
                case let .failure(e): self?.failPending(e)
                }
            }
        } else {
            manager.connect(peripheral, options: nil)
        }
    }

    private func attachStanding(_ peripheral: CBPeripheral) {
        guard pending?.finished == false else { return }
        logger.info("standing connect to \(peripheral.identifier.uuidString) (state \(peripheral.state.rawValue))")
        pending?.standing = peripheral
        if peripheral.state == .connected {
            let wrapper = OttaiBLEPeripheral(peripheral: peripheral, manager: manager, queue: queue)
            pending?.wrapper = wrapper
            wrapper.beginDiscovery { [weak self] result in
                switch result {
                case .success: self?.finishPending(wrapper)
                case let .failure(e): self?.failPending(e)
                }
            }
        } else {
            manager.connect(peripheral, options: nil)
        }
    }

    private func finishDiscovery() {
        guard var d = pendingDiscovery, !d.finished else { return }
        d.finished = true
        pendingDiscovery = nil
        manager.stopScan()
        d.timeout.cancel()
        d.settle?.cancel()
        let sorted = d.found.values.sorted { $0.rssi > $1.rssi }
        logger.info(
            "discovery heard \(sorted.count) sensor(s): "
                + sorted.map { "\(OttaiRedact.mac($0.mac)) rssi=\($0.rssi)" }.joined(separator: ", ")
        )
        d.continuation.resume(returning: sorted)
    }

    private func failPending(_ error: Error) { guard var p = pending, !p.finished else { return }
        p.finished = true
        pending = p
        manager.stopScan()
        p.timeout.cancel()
        if let wrapper = p.wrapper {
            manager.cancelPeripheralConnection(wrapper.peripheral)
        }
        if let standing = p.standing, standing !== p.wrapper?.peripheral {
            manager.cancelPeripheralConnection(standing)
        }
        pending = nil
        p.continuation.resume(throwing: error)
    }

    private func finishPending(_ peripheral: OttaiBLEPeripheral) {
        guard var p = pending, !p.finished else { return }
        p.finished = true
        p.timeout.cancel()
        manager.stopScan()
        if let standing = p.standing, standing !== peripheral.peripheral {
            manager.cancelPeripheralConnection(standing)
        }
        pending = nil
        live = peripheral
        p.continuation.resume(returning: peripheral)
    }
}

extension OttaiBLECentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiters = powerOnWaiters
        powerOnWaiters = []
        switch central.state {
        case .poweredOn:
            waiters.forEach { $0.resume() }
        default:
            waiters.forEach { $0.resume(throwing: BLEError.bluetoothUnavailable(central.state)) }
            // The radio going away (toggled off, reset, unauthorized...) silently
            // drops any live/pending connection at the OS level without a matching
            // didDisconnectPeripheral callback, so nothing downstream would otherwise
            // learn the link is gone. Tear it down here so the normal disconnect path
            // (monitor's frame stream ends -> handleMonitorDisconnect -> scheduleReconnect)
            // runs instead of the sensor being stranded until Bluetooth comes back.
            if let p = pending, !p.finished {
                failPending(BLEError.bluetoothUnavailable(central.state))
            }
            if live != nil {
                live?.handleDisconnect()
                live = nil
            }
        }
    }

    public func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restoredPeripherals = peripherals
        logger.info("state restoration: \(peripherals.count) peripheral(s) handed back by iOS")
        // Fast-path a reconnect that was already in flight when iOS relaunched us.
        if let p = pending, !p.finished, let id = p.expectedPeripheralID,
           let restored = peripherals.first(where: { $0.identifier == id })
        {
            restoredPeripherals.removeAll { $0.identifier == id }
            attachRestored(restored)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        if var d = pendingDiscovery, !d.finished {
            let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            guard let advMAC = Self.advertisedMAC(fromManufacturerData: mfg) else { return }
            let rssi = RSSI.intValue
            if let existing = d.found[peripheral.identifier], existing.rssi >= rssi {
                // keep existing stronger sighting
            } else {
                d.found[peripheral.identifier] = DiscoveredSensor(
                    mac: advMAC, rssi: rssi, peripheralID: peripheral.identifier
                )
            }
            if let target = d.targetMAC {
                guard advMAC == target else { return }
                d.found[peripheral.identifier] = DiscoveredSensor(
                    mac: advMAC, rssi: rssi, peripheralID: peripheral.identifier
                )
                pendingDiscovery = d
                finishDiscovery()
                return
            }
            if d.settle == nil {
                let settleItem = DispatchWorkItem { [weak self] in self?.finishDiscovery() }
                d.settle = settleItem
                queue.asyncAfter(deadline: .now() + d.settleWindow, execute: settleItem)
            }
            pendingDiscovery = d
            return
        }
        guard let p = pending, !p.finished else { return }
        // A restored/standing attach is already in flight; don't hijack it.
        guard p.wrapper == nil else { return }
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        guard let advMAC = Self.advertisedMAC(fromManufacturerData: mfg), advMAC == p.targetMAC else {
            return
        }
        logger.debug("matched \(OttaiRedact.mac(advMAC)), connecting")
        central.stopScan()
        if let standing = p.standing, standing !== peripheral {
            central.cancelPeripheralConnection(standing)
            pending?.standing = nil
        }
        let wrapper = OttaiBLEPeripheral(peripheral: peripheral, manager: central, queue: queue)
        pending?.wrapper = wrapper
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("ble conected \(peripheral.identifier.uuidString)")
        guard let p = pending, !p.finished else { return }
        if let wrapper = p.wrapper {
            guard wrapper.peripheral === peripheral else { return }
            wrapper.beginDiscovery { [weak self] result in
                switch result {
                case .success: self?.finishPending(wrapper)
                case let .failure(e): self?.failPending(e)
                }
            }
        } else if p.standing === peripheral {
            // The standing connect beat the scan; no advertisement was needed.
            logger.info("standing connect won (no scan match needed)")
            central.stopScan()
            let wrapper = OttaiBLEPeripheral(peripheral: peripheral, manager: central, queue: queue)
            pending?.wrapper = wrapper
            wrapper.beginDiscovery { [weak self] result in
                switch result {
                case .success: self?.finishPending(wrapper)
                case let .failure(e): self?.failPending(e)
                }
            }
        }
    }

    public func centralManager(
        _: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let p = pending, !p.finished,
              p.wrapper?.peripheral === peripheral || p.standing === peripheral else { return }
        failPending(BLEError.connectFailed(error?.localizedDescription ?? "unknown"))
    }

    public func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.info(
            "ble disconnected id=\(peripheral.identifier.uuidString)"
                + (error.map { " error=\($0.localizedDescription)" } ?? " (orderly)")
        )
        // If the drop happens mid-connect, fail the pending request; otherwise the
        // live wrapper ends its notify streams (so the monitor sees a disconnect).
        if let p = pending, !p.finished,
           p.wrapper?.peripheral === peripheral || p.standing === peripheral
        {
            failPending(BLEError.disconnected(error?.localizedDescription ?? "peer closed"))
        } else if live?.peripheral === peripheral {
            live?.handleDisconnect()
            live = nil
        }
    }
}

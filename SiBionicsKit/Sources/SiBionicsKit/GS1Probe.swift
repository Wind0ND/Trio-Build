#if os(iOS)
import CoreBluetooth
import Foundation
import Observation

/// A foreground GATT discovery check for the exact sensor chosen by the user.
@MainActor
@Observable
final class GS1Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Phase: Equatable {
        case idle, searching, connecting, inspecting, ready, unavailable, notFound, failed, stopped
    }

    private enum Stage: String { case scan, match, connection, service, characteristic }
    private enum Outcome: String { case started, matched, succeeded, unavailable, timedOut = "timed_out", failed, stopped }

    private static let service = CBUUID(string: "FF30")
    private static let dataCharacteristic = CBUUID(string: "FF31")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var target: GS1Target?
    private var timeout: Task<Void, Never>?
    private var inspectionStage: Stage = .service
    private(set) var phase: Phase = .idle

    var isActive: Bool { phase == .searching || phase == .connecting || phase == .inspecting }

    func start(_ target: GS1Target) {
        guard !isActive else { return }
        self.target = target
        phase = .searching
        record(.scan, .started)
        armTimeout(for: .searching, seconds: 45)
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func stop() {
        guard isActive else { return }
        finish(.stopped, stage: stage, outcome: .stopped)
    }

    private var stage: Stage {
        switch phase {
        case .connecting: .connection
        case .inspecting: inspectionStage
        default: .scan
        }
    }

    private func armTimeout(for expectedPhase: Phase, seconds: Int) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.phase == expectedPhase else { return }
            self.finish(expectedPhase == .searching ? .notFound : .failed, stage: self.stage, outcome: .timedOut)
        }
    }

    private func finish(_ result: Phase, stage: Stage, outcome: Outcome) {
        phase = result
        record(stage, outcome)
        timeout?.cancel()
        timeout = nil
        peripheral?.delegate = nil
        if let central, central.state == .poweredOn {
            central.stopScan()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        central?.delegate = nil
        peripheral = nil
        central = nil
        target = nil
    }

    private func record(_ stage: Stage, _ outcome: Outcome) {
        NotificationCenter.default.post(name: .init("com.trio.diagnostics.event"), object: nil, userInfo: [
            "schema": 1, "feature": "sibionics", "stage": stage.rawValue, "outcome": outcome.rawValue
        ])
    }

    // The central and peripheral delegates use the main queue chosen in start(_:).
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central === self.central, isActive else { return }
            switch central.state {
            case .poweredOn:
                if phase == .searching, !central.isScanning {
                    central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                }
            case .unknown, .resetting: break
            default: finish(.unavailable, stage: stage, outcome: .unavailable)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        MainActor.assumeIsolated {
            guard central === self.central, phase == .searching,
                  (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) != false
            else { return }
            let names = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            guard target?.matches(localName: names) == true else { return }
            self.peripheral = peripheral
            phase = .connecting
            record(.match, .matched)
            central.stopScan()
            armTimeout(for: .connecting, seconds: 15)
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === self.peripheral, phase == .connecting else { return }
            inspectionStage = .service
            phase = .inspecting
            record(.connection, .succeeded)
            armTimeout(for: .inspecting, seconds: 15)
            peripheral.delegate = self
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error _: Error?) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === self.peripheral, phase == .connecting else { return }
            finish(.failed, stage: .connection, outcome: .failed)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: Error?) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === self.peripheral, isActive else { return }
            finish(.failed, stage: stage, outcome: .failed)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral, phase == .inspecting, inspectionStage == .service else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
                finish(.failed, stage: .service, outcome: .failed)
                return
            }
            record(.service, .succeeded)
            inspectionStage = .characteristic
            peripheral.discoverCharacteristics([Self.dataCharacteristic], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral, phase == .inspecting, inspectionStage == .characteristic,
                  service.uuid == Self.service else { return }
            let found = error == nil && service.characteristics?.contains { characteristic in
                characteristic.uuid == Self.dataCharacteristic &&
                    (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate))
            } == true
            finish(found ? .ready : .failed, stage: .characteristic, outcome: found ? .succeeded : .failed)
        }
    }
}
#endif

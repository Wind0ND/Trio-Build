#if canImport(CoreBluetooth) && os(iOS)
import CoreBluetooth
import Foundation

@MainActor
public protocol AiDEXProbeTransport: AnyObject {
    var onEvent: ((AiDEXProbeTransportEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// Foreground-only scan for AiDEX advertisements. It never connects, writes,
/// reads a GATT characteristic, calibrates or activates a sensor.
@MainActor
public final class AiDEXBluetoothProbe: NSObject, AiDEXProbeTransport, CBCentralManagerDelegate {
    public var onEvent: ((AiDEXProbeTransportEvent) -> Void)?

    private var central: CBCentralManager?
    private var isScanning = false

    public override init() {
        super.init()
    }

    public func start() {
        guard central == nil else { return }
        isScanning = false
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    public func stop() {
        if let central, central.state == .poweredOn, isScanning {
            central.stopScan()
        }
        isScanning = false
        central?.delegate = nil
        central = nil
    }

    private func startScanning() {
        guard !isScanning, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        onEvent?(.scanningStarted)
    }

    private func handleState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            onEvent?(.unavailable(.poweredOff))
        case .unauthorized:
            onEvent?(.unavailable(.unauthorized))
        case .unsupported:
            onEvent?(.unavailable(.unsupported))
        case .resetting:
            onEvent?(.unavailable(.notReady))
        case .unknown:
            break
        @unknown default:
            onEvent?(.unavailable(.notReady))
        }
    }

    private func handleDiscovery(
        central: CBCentralManager,
        peripheralID: UUID,
        localName: String?,
        manufacturerData: Data?,
        receivedAt: Date
    ) {
        // A callback from a superseded central or after stop is stale.
        guard central === self.central, isScanning else { return }
        onEvent?(.advertisement(
            peripheralID: peripheralID,
            localName: localName,
            manufacturerData: manufacturerData,
            receivedAt: receivedAt
        ))
    }

    // CoreBluetooth delivers these on the main queue requested above. Only the
    // advertisement's own local-name value is used; `CBPeripheral.name` may be
    // a cached stale name and is deliberately never read.
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            handleState(central)
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let peripheralID = peripheral.identifier
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let receivedAt = Date()
        MainActor.assumeIsolated {
            handleDiscovery(
                central: central,
                peripheralID: peripheralID,
                localName: localName,
                manufacturerData: manufacturerData,
                receivedAt: receivedAt
            )
        }
    }
}
#endif

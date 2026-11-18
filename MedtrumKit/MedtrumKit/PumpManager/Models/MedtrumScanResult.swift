import CoreBluetooth
import Foundation

public enum MedtrumScanResult {
    case success(peripheral: CBPeripheral, pumpSN: Data, deviceType: UInt8, version: UInt8)
    case failure(error: MedtrumScanError)
}

public enum MedtrumScanError: LocalizedError {
    case invalidBluetoothState(state: CBManagerState)
    case noSerialNumberAvailable
    case alreadyScanning

    public var errorDescription: String? {
        switch self {
        case let .invalidBluetoothState(state: state):
            return String(localized: "Invalid Bluetooth state: \(String(describing: state))")
        case .noSerialNumberAvailable:
            return String(localized: "No Serial number setup. Please complete activation flow...")
        case .alreadyScanning:
            return String(localized: "Already scanning")
        }
    }
}

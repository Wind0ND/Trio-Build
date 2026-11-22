import Foundation

enum MedtrumWriteResult<T> {
    case success(data: T)
    case failure(error: MedtrumWriteError)
}

enum MedtrumWriteError: LocalizedError {
    case timeout
    case alreadyRunning
    case noData
    case invalidData
    case invalidResponse(code: UInt16)
    case noManager
    case noWriteCharacteristic
    case persistenceFailed

    /// A reply lost or damaged after transmission cannot establish whether delivery started.
    var deliveryMayHaveStarted: Bool {
        switch self {
        case .timeout, .noData, .invalidData:
            return true
        case .alreadyRunning, .invalidResponse, .noManager, .noWriteCharacteristic, .persistenceFailed:
            return false
        }
    }

    public var errorDescription: String {
        switch self {
        case .persistenceFailed:
            return String(localized: "Could not save pump delivery state. No command was sent.")
        case .timeout:
            return String(localized: "A command timeout is hit")
        case .alreadyRunning:
            return String(localized: "A command is already running")
        case .noData:
            return String(localized: "No data")
        case .invalidData:
            return String(localized: "Invalid data received")
        case let .invalidResponse(code):
            return String(localized: "Invalid response code: \(String(describing: code))")
        case .noManager:
            return String(localized: "No peripheral manager")
        case .noWriteCharacteristic:
            return String(localized: "No write characteristic. Device might be disconnected")
        }
    }
}

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

    public var errorDescription: String {
        switch self {
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

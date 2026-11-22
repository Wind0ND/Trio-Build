public enum MedtrumConnectError: LocalizedError {
    case failedToDiscoverServices(localizedError: String)
    case failedToDiscoverCharacteristics(localizedError: String)
    case failedToEnableNotify(localizedError: String)
    case failedToCompleteAuthorizationFlow(localizedError: String)
    case authorizationTimedOut
    case authorizationRejected(code: UInt16)
    case failedToFindDevice
    case failedToConnectToDevice
    case isBolussing
    case isSuspended
    case automaticBolusUnavailable

    public var errorDescription: String? {
        switch self {
        case let .failedToDiscoverServices(localizedErr):
            return localizedErr
        case let .failedToDiscoverCharacteristics(localizedErr):
            return localizedErr
        case let .failedToEnableNotify(localizedErr):
            return localizedErr
        case let .failedToCompleteAuthorizationFlow(localizedErr):
            return localizedErr
        case .authorizationTimedOut:
            return MedtrumWriteError.timeout.errorDescription
        case let .authorizationRejected(code):
            return MedtrumWriteError.invalidResponse(code: code).errorDescription
        case .failedToConnectToDevice:
            return String(
                localized: "Failed to connect to patch -> Timeout reached",
                comment: "MedtrumError patch failedToConnectToDevice"
            )
        case .failedToFindDevice:
            return String(localized: "Failed to connect to patch", comment: "MedtrumError patch failedToFindDevice")
        case .isBolussing:
            return String(localized: "Bolus issue. Patch is already bolussing", comment: "MedtrumError patch bolussing")
        case .isSuspended:
            return String(localized: "Bolus issue. Patch is suspended. Resume delivery", comment: "MedtrumError patch suspended")
        case .automaticBolusUnavailable:
            return String(localized: "Automatic bolus unavailable. Check patch status.", bundle: Bundle(for: MedtrumPumpManager.self), comment: "Medtrum automatic bolus capability restriction")
        }
    }

    init(authorizationError: MedtrumWriteError) {
        switch authorizationError {
        case .timeout: self = .authorizationTimedOut
        case let .invalidResponse(code): self = .authorizationRejected(code: code)
        default: self = .failedToCompleteAuthorizationFlow(localizedError: authorizationError.localizedDescription)
        }
    }
}

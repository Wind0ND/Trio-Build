import Foundation

public enum MedtrumActivatePatchResult {
    case success
    case failure(error: MedtrumActivatePatchError)
}

public enum MedtrumActivatePatchError: LocalizedError {
    case connectionFailure(reason: String)
    case patchNotActivatable(state: PatchState)
    case unknownError(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailure(reason: reason):
            return String(localized: "Connection failure: \(String(describing: reason))")
        case let .patchNotActivatable(state: state):
            return String(localized: "This patch can no longer be activated (\(String(describing: state.description))). Please replace it with a new patch.")
        case let .unknownError(reason: reason):
            return String(localized: "Unknown error: \(String(describing: reason))")
        }
    }
}

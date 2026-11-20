import AppIntents
import PrivacyKit

/// Shared by app and widget. The system executes LiveActivityIntent in the app process.
struct HiroPrivateRecoveryIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Refresh activity"
    static var description = IntentDescription("Refresh the current activity in the background.")
    static var openAppWhenRun = false
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor func perform() async throws -> some IntentResult {
        _ = await PrivateRecoveryBridge.shared.request()
        return .result()
    }
}

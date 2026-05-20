import Foundation

/// Shared settings keys and defaults for relay configuration, model selection, and input modes.
/// Apps extend this with their own app-specific settings.
public enum NeoxCoreSettings {
    // MARK: - UserDefaults Keys

    public static let relayHostKey = "relayHost"
    public static let relayPortKey = "relayPort"
    public static let useDevServerKey = "useDevServer"
    public static let devServerPortKey = "devServerPort"
    public static let selectedModelKey = "selectedModel"
    public static let userIdKey = "neoxUserId"
    public static let showUsageInChatKey = "showUsageInChat"
    public static let showProgressInChatKey = "showProgressInChat"
    public static let showBuildInChatKey = "showBuildInChat"
    public static let useDirectProviderKey = "useDirectProvider"

    // Utility model keys — dedicated models for specific tasks
    public static let visionModelKey = "visionModel"       // "providerId/modelId" or empty for on-device
    public static let ttsModelKey = "ttsModel"             // "providerId/modelId" or empty for on-device
    public static let sttModelKey = "sttModel"             // "providerId/modelId" or empty for on-device

    // Feedback (Send Feedback + auto crash report) — see Feedback target
    public static let feedbackEndpointKey = "feedbackEndpoint"
    public static let feedbackAutoCrashReportKey = "feedbackAutoCrashReport"

    // MARK: - Defaults

    public static let defaultRelayHost = "relay.ai.qili2.com"
    public static let defaultRelayPort: UInt16 = 443
    public static let defaultModel = "deepseek-v4-flash"
    public static let defaultDevServerPort = 9223
    public static let defaultProvider = "deepseek"

    /// Default Feedback endpoint. Empty unless set per-app via the bootstrap
    /// helper. Apps should ship their own endpoint as a build-time constant
    /// rather than asking end users to type it in.
    public static let defaultFeedbackEndpoint = ""

    // MARK: - Helpers

    /// Save relay settings to UserDefaults.
    public static func saveRelaySettings(relayHost: String, relayPort: UInt16) {
        let defaults = UserDefaults.standard
        defaults.set(relayHost, forKey: relayHostKey)
        defaults.set(Int(relayPort), forKey: relayPortKey)
    }
}

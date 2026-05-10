import Foundation

/// Shared settings keys and defaults for relay configuration, model selection, and input modes.
/// Apps extend this with their own app-specific settings.
public enum NeoxCoreSettings {
    // MARK: - UserDefaults Keys

    public static let useLocalRelayKey = "useLocalRelay"
    public static let localRelayURLKey = "localRelayURL"
    public static let relayHostKey = "relayHost"
    public static let relayPortKey = "relayPort"
    public static let useDevServerKey = "useDevServer"
    public static let devServerPortKey = "devServerPort"
    public static let enableTextInputKey = "enableTextInput"
    public static let enableSpeechInputKey = "enableSpeechInput"
    public static let enableAttachmentInputKey = "enableAttachmentInput"
    public static let selectedModelKey = "selectedModel"
    public static let userIdKey = "neoxUserId"
    public static let showUsageInChatKey = "showUsageInChat"
    public static let showProgressInChatKey = "showProgressInChat"
    public static let showBuildInChatKey = "showBuildInChat"
    public static let useDirectProviderKey = "useDirectProvider"
    public static let enabledModelIdsKey = "enabledModelIds"

    // Feedback (Send Feedback + auto crash report) — see Feedback target
    public static let feedbackEndpointKey = "feedbackEndpoint"
    public static let feedbackAutoCrashReportKey = "feedbackAutoCrashReport"

    // MARK: - Defaults

    public static let defaultRelayHost = "relay.ai.qili2.com"
    public static let defaultRelayPort: UInt16 = 443
    public static let defaultLocalRelayURL = "http://10.0.0.111:8765"
    public static let defaultModel = "relay-deepseek-v4-flash"
    public static let defaultDevServerPort = 9223
    public static let defaultProvider = "ccm-relay"

    /// Default set of enabled model IDs on first launch — all CCM-relay
    /// variants. Direct-provider models stay opt-in until the user supplies
    /// an API key for that provider.
    public static let defaultEnabledModelIds: Set<String> = [
        "relay-deepseek-v4-flash",
        "relay-deepseek-v4-pro",
        "relay-claude-sonnet-4",
        "relay-claude-sonnet-4.5",
        "relay-claude-sonnet-4.6",
        "relay-gpt-4.1",
    ]

    /// Default Feedback endpoint. Empty unless set per-app via the bootstrap
    /// helper. Apps should ship their own endpoint as a build-time constant
    /// rather than asking end users to type it in.
    public static let defaultFeedbackEndpoint = ""

    // MARK: - Helpers

    /// Parse a relay URL string into host/port. Returns nil if unparseable.
    public static func parseRelayURL(_ raw: String) -> (host: String, port: UInt16)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host else { return nil }
        let port = UInt16(url.port ?? 8765)
        return (host, port)
    }

    /// Save relay settings to UserDefaults.
    public static func saveRelaySettings(useLocalRelay: Bool, localRelayURL: String, relayHost: String, relayPort: UInt16) {
        let defaults = UserDefaults.standard
        defaults.set(useLocalRelay, forKey: useLocalRelayKey)
        defaults.set(localRelayURL, forKey: localRelayURLKey)
        defaults.set(relayHost, forKey: relayHostKey)
        defaults.set(Int(relayPort), forKey: relayPortKey)
    }
}

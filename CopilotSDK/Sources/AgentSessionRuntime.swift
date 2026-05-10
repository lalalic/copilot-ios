import Foundation

// MARK: - AgentSessionRuntime

/// Provider-neutral session interface used by the UI layer.
/// This is the compatibility seam that replaces CopilotSession and CopilotAgent for app code.
///
/// Responsibilities:
/// - Create or restore sessions
/// - Send prompts
/// - Steer or follow-up while streaming
/// - Subscribe to message, tool, error, and usage events
/// - Expose current session state
/// - Persist and restore conversation history
/// - Support local abort and cleanup
public protocol AgentSessionRuntime: AnyObject, Sendable {

    /// Unique identifier for the current session.
    var sessionId: String { get }

    /// Current state of the session.
    var state: SessionState { get async }

    /// The model currently in use.
    var currentModel: ModelInfo? { get async }

    // MARK: - Session Lifecycle

    /// Create a new session with the given configuration.
    func createSession(config: RuntimeSessionConfig) async throws

    /// Restore a session from local persistence.
    func restoreSession(name: String) async throws

    /// Send a user prompt.
    func send(prompt: String, attachments: [RuntimeAttachment]?) async throws

    /// Inject a steering message while the assistant is working.
    func steer(message: String) async throws

    /// Abort the current turn.
    func abort() async

    /// Destroy the session and release resources.
    func destroy() async

    // MARK: - Event Subscription

    /// Subscribe to runtime events. Returns a handle that can be used to unsubscribe.
    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (RuntimeEvent) -> Void) -> RuntimeSubscription

    /// Remove a subscription.
    func unsubscribe(_ subscription: RuntimeSubscription)

    // MARK: - User Input Response

    /// Respond to a user input request from the runtime.
    func respondToUserInput(requestId: String, responses: [String: String]) async throws

    // MARK: - History

    /// Get the current conversation messages.
    func getMessages() async throws -> [RuntimeMessage]

    /// Clear the session history.
    func clearHistory() async throws
}

// MARK: - SessionState

/// The state of an agent session.
public enum SessionState: Sendable, Equatable {
    /// Not connected / no session.
    case disconnected
    /// Session is being created or restored.
    case connecting
    /// Session is idle, ready for input.
    case idle
    /// Session is processing a prompt.
    case working
    /// Context compaction is in progress.
    case compacting
    /// Waiting for user input.
    case waitingForUser
    /// An error occurred.
    case error(String)
}

// MARK: - RuntimeSessionConfig

/// Provider-neutral session configuration.
public struct RuntimeSessionConfig: Sendable {
    /// Session name / identifier.
    public var sessionName: String?
    /// Model to use.
    public var model: String?
    /// Provider to use (e.g. "openai", "anthropic", "copilot").
    public var provider: String?
    /// System message / instructions.
    public var systemMessage: String?
    /// Tools available in this session.
    public var tools: [ToolDefinition]?
    /// Working directory for tool execution.
    public var workingDirectory: String?
    /// Whether to enable streaming.
    public var streaming: Bool
    /// Reasoning effort level (for models that support it). Defaults to "high".
    public var reasoningEffort: String?
    /// Custom provider configuration (base URL, etc.).
    public var providerConfig: RuntimeProviderConfig?

    public init(
        sessionName: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        systemMessage: String? = nil,
        tools: [ToolDefinition]? = nil,
        workingDirectory: String? = nil,
        streaming: Bool = true,
        reasoningEffort: String? = "high",
        providerConfig: RuntimeProviderConfig? = nil
    ) {
        self.sessionName = sessionName
        self.model = model
        self.provider = provider
        self.systemMessage = systemMessage
        self.tools = tools
        self.workingDirectory = workingDirectory
        self.streaming = streaming
        self.reasoningEffort = reasoningEffort
        self.providerConfig = providerConfig
    }
}

// MARK: - RuntimeProviderConfig

/// Provider endpoint configuration for BYOK mode in the new runtime layer.
/// This is distinct from the legacy `ProviderConfig` used by relay-backed sessions.
public struct RuntimeProviderConfig: Sendable {
    /// Base URL for the API (e.g. "https://api.openai.com/v1").
    public var baseURL: String?
    /// API key (injected at request time from CredentialStore).
    public var apiKey: String?
    /// Custom headers.
    public var headers: [String: String]?

    public init(baseURL: String? = nil, apiKey: String? = nil, headers: [String: String]? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.headers = headers
    }
}

// MARK: - RuntimeAttachment

/// An attachment sent with a prompt.
public struct RuntimeAttachment: Sendable {
    public let name: String
    public let data: Data
    public let mimeType: String

    public init(name: String, data: Data, mimeType: String) {
        self.name = name
        self.data = data
        self.mimeType = mimeType
    }

    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
}

// MARK: - RuntimeMessage

/// A provider-neutral message in a conversation.
public struct RuntimeMessage: Sendable, Identifiable {
    public let id: String
    public let role: Role
    public let content: String
    public let timestamp: Date
    public let model: String?
    public let toolCalls: [ToolCallRecord]?
    public let toolResult: ToolResultRecord?
    public let thinking: String?

    public enum Role: String, Sendable {
        case user
        case assistant
        case tool
        case system
    }

    public struct ToolCallRecord: Sendable {
        public let id: String
        public let name: String
        public let arguments: String

        public init(id: String, name: String, arguments: String) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public struct ToolResultRecord: Sendable {
        public let toolCallId: String
        public let toolName: String
        public let content: String
        public let isError: Bool

        public init(toolCallId: String, toolName: String, content: String, isError: Bool = false) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.content = content
            self.isError = isError
        }
    }

    public init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        timestamp: Date = Date(),
        model: String? = nil,
        toolCalls: [ToolCallRecord]? = nil,
        toolResult: ToolResultRecord? = nil,
        thinking: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.model = model
        self.toolCalls = toolCalls
        self.toolResult = toolResult
        self.thinking = thinking
    }
}

// MARK: - RuntimeSubscription

/// Handle for an event subscription. Used to unsubscribe.
public final class RuntimeSubscription: Sendable {
    public let id: String

    public init(id: String = UUID().uuidString) {
        self.id = id
    }
}

extension RuntimeSubscription: Hashable {
    public static func == (lhs: RuntimeSubscription, rhs: RuntimeSubscription) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - ModelInfo

/// Metadata about a model.
public struct ModelInfo: Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let supportsReasoning: Bool
    public let supportsImages: Bool
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let pricing: ModelPricing?

    public init(
        id: String,
        name: String,
        provider: String,
        supportsReasoning: Bool = false,
        supportsImages: Bool = true,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        pricing: ModelPricing? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.supportsReasoning = supportsReasoning
        self.supportsImages = supportsImages
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.pricing = pricing
    }
}

/// Pricing metadata for local cost estimation.
public struct ModelPricing: Sendable {
    /// Cost per million input tokens in USD.
    public let inputPerMillion: Double
    /// Cost per million output tokens in USD.
    public let outputPerMillion: Double

    public init(inputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    /// Calculate the cost for a given token count.
    public func cost(promptTokens: Int, completionTokens: Int) -> Double {
        (Double(promptTokens) * inputPerMillion + Double(completionTokens) * outputPerMillion) / 1_000_000.0
    }
}

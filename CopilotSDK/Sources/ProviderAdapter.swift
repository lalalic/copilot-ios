import Foundation

// MARK: - ProviderAdapter

/// Each provider adapter handles auth injection, request formatting, streaming parsing,
/// tool call translation, usage extraction, and model capability metadata.
///
/// The adapter must emit normalized RuntimeEvents, not provider-native event payloads.
public protocol ProviderAdapter: Sendable {

    /// Provider identifier (e.g. "openai", "anthropic", "copilot").
    var providerId: String { get }

    /// Display name for the provider.
    var displayName: String { get }

    /// List available models from this provider.
    func listModels() async throws -> [ModelInfo]

    /// Send a chat completion request and stream back RuntimeEvents.
    ///
    /// - Parameters:
    ///   - messages: Conversation history in provider-neutral format.
    ///   - model: Model identifier to use.
    ///   - systemMessage: System prompt.
    ///   - tools: Tool definitions available for this request.
    ///   - config: Provider-specific configuration.
    ///   - onEvent: Callback for each runtime event as it arrives.
    func streamCompletion(
        messages: [ProviderMessage],
        model: String,
        systemMessage: String?,
        tools: [ProviderToolDefinition],
        config: ProviderRequestConfig,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws

    /// Abort the current streaming request.
    func abort() async

    /// Validate that credentials are valid (e.g. test API key).
    func validateCredentials(apiKey: String, baseURL: String?) async throws -> Bool
}

// MARK: - ProviderMessage

/// Provider-neutral message format for adapter input.
public struct ProviderMessage: Sendable {
    public let role: Role
    public let content: [ContentPart]
    public let toolCalls: [ProviderToolCall]?
    public let toolCallId: String?
    public let name: String?
    public let reasoningContent: String?

    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public enum ContentPart: Sendable {
        case text(String)
        case image(data: Data, mimeType: String)
    }

    public init(
        role: Role,
        content: [ContentPart],
        toolCalls: [ProviderToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
        self.reasoningContent = reasoningContent
    }

    /// Convenience for text-only messages.
    public init(role: Role, text: String) {
        self.init(role: role, content: [.text(text)])
    }
}

// MARK: - ProviderToolCall

/// A tool call as emitted by the provider during streaming.
public struct ProviderToolCall: Sendable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - ProviderToolDefinition

/// Tool definition in the format expected by provider adapters.
public struct ProviderToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the tool's parameters.
    public let parametersSchema: [String: Any]

    public init(name: String, description: String, parametersSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
    }
}

// MARK: - ProviderRequestConfig

/// Configuration for a single provider request.
public struct ProviderRequestConfig: Sendable {
    public let apiKey: String
    public let baseURL: String?
    public let maxTokens: Int?
    public let temperature: Double?
    public let reasoningEffort: String?
    public let streaming: Bool
    public let customHeaders: [String: String]?

    public init(
        apiKey: String,
        baseURL: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        reasoningEffort: String? = nil,
        streaming: Bool = true,
        customHeaders: [String: String]? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.streaming = streaming
        self.customHeaders = customHeaders
    }
}

// MARK: - ProviderToolDefinition ↔ ToolDefinition Bridge

extension ProviderToolDefinition {

    /// Create a ProviderToolDefinition from a CopilotSDK ToolDefinition.
    public init(from tool: ToolDefinition) {
        self.name = tool.name
        self.description = tool.description ?? ""
        // Convert JSONValue parameters to dictionary
        if let params = tool.parameters {
            self.parametersSchema = params.toDictionary()
        } else {
            self.parametersSchema = [:]
        }
    }
}

// MARK: - JSONValue Dictionary Bridge

extension JSONValue {

    /// Convert JSONValue to a native dictionary for provider APIs.
    func toDictionary() -> [String: Any] {
        switch self {
        case .object(let dict):
            var result: [String: Any] = [:]
            for (key, value) in dict {
                result[key] = value.toAny()
            }
            return result
        default:
            return [:]
        }
    }

    /// Convert JSONValue to a native Any value.
    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { $0.toAny() }
        case .object(let dict):
            var result: [String: Any] = [:]
            for (key, value) in dict {
                result[key] = value.toAny()
            }
            return result
        }
    }
}

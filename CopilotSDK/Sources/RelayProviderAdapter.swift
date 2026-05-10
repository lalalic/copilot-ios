import Foundation

// MARK: - RelayProviderAdapter
//
// Thin convenience wrapper over OpenAIAdapter pre-configured to talk to the
// CCM-style LLM relay (or any deployment that exposes the same shape):
//
//     POST {baseURL}/chat/completions    (OpenAI-compatible)
//
// The relay multiplexes upstream providers (DeepSeek, Anthropic via OpenAI
// chat-completions shim, Qwen/DashScope, etc.) behind a single bearer-token
// authenticated endpoint, and is the path co-harness/ccm-harness already use
// for production billing.
//
// Auth:
//   - bearer token is supplied via `ProviderRequestConfig.apiKey` per call
//   - clients should store it in CredentialStore under provider id "ccm-relay"
//
// Default base URL points at the CCM relay deployment; pass a different value
// to target a self-hosted relay.

public final class RelayProviderAdapter: ProviderAdapter, @unchecked Sendable {
    private let inner: OpenAIAdapter

    public var providerId: String { inner.providerId }
    public var displayName: String { inner.displayName }

    public init(
        providerId: String = "ccm-relay",
        displayName: String = "CCM Relay",
        defaultBaseURL: String = "https://relay.ai.qili2.com/llm/v1",
        usageCalculator: UsageCalculator? = nil
    ) {
        self.inner = OpenAIAdapter(
            providerId: providerId,
            displayName: displayName,
            defaultBaseURL: defaultBaseURL,
            usageCalculator: usageCalculator
        )
    }

    public func listModels() async throws -> [ModelInfo] {
        try await inner.listModels()
    }

    public func streamCompletion(
        messages: [ProviderMessage],
        model: String,
        systemMessage: String?,
        tools: [ProviderToolDefinition],
        config: ProviderRequestConfig,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws {
        try await inner.streamCompletion(
            messages: messages,
            model: model,
            systemMessage: systemMessage,
            tools: tools,
            config: config,
            onEvent: onEvent
        )
    }

    public func abort() async {
        await inner.abort()
    }

    public func validateCredentials(apiKey: String, baseURL: String?) async throws -> Bool {
        try await inner.validateCredentials(apiKey: apiKey, baseURL: baseURL)
    }
}

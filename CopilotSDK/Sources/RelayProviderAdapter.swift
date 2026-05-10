import Foundation

// MARK: - RelayProviderAdapter
//
// Thin convenience wrapper over OpenAIAdapter pre-configured to talk to the
// LLM relay (or any deployment that exposes the same shape):
//
//     POST {baseURL}/chat/completions    (OpenAI-compatible)
//
// The relay multiplexes upstream providers (DeepSeek today; more later)
// behind a single bearer-token authenticated endpoint and is the path
// co-harness/ccm-harness already use for production billing.
//
// Auth:
//   - bearer token is supplied via `ProviderRequestConfig.apiKey` per call;
//     when the platform-default relay endpoint is used, no key is required
//     and the relay debits the user's platform credit
//   - clients should store it in CredentialStore under provider id "relay"
//
// Default base URL points at the platform relay deployment; pass a different
// value to target a self-hosted relay.

public final class RelayProviderAdapter: ProviderAdapter, @unchecked Sendable {
    private let inner: OpenAIAdapter

    public var providerId: String { inner.providerId }
    public var displayName: String { inner.displayName }

    public init(
        providerId: String = "relay",
        displayName: String = "Relay",
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
        // Strip the `relay-` registry prefix so the upstream relay receives
        // the canonical upstream model name (e.g. `deepseek-v4-flash`).
        let upstreamModel = model.hasPrefix("relay-") ? String(model.dropFirst("relay-".count)) : model
        try await inner.streamCompletion(
            messages: messages,
            model: upstreamModel,
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

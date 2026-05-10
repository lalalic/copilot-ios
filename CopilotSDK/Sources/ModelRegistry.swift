import Foundation

// MARK: - ModelRegistry

/// Local model catalog replacing relay model discovery.
/// Provides bundled defaults for known models with optional remote refresh later.
public final class ModelRegistry: @unchecked Sendable {

    /// All registered models, keyed by "\(provider):\(modelId)".
    private var models: [String: ModelInfo] = [:]
    private let lock = NSLock()

    /// The default model to use when none is specified.
    public var defaultModelId: String = "deepseek-v4-flash"
    /// The default provider.
    public var defaultProviderId: String = "deepseek"

    public init() {
        registerDefaults()
    }

    /// Return the default model info.
    public var defaultModel: ModelInfo? {
        model(provider: defaultProviderId, id: defaultModelId)
    }

    // MARK: - Query

    /// Get a model by provider and model ID.
    public func model(provider: String, id: String) -> ModelInfo? {
        lock.lock()
        defer { lock.unlock() }
        return models[key(provider: provider, id: id)]
    }

    /// Get a model by just its model ID (searches across all providers).
    public func model(id: String) -> ModelInfo? {
        lock.lock()
        defer { lock.unlock() }
        return models.values.first { $0.id == id }
    }

    /// List all models for a given provider.
    public func models(for provider: String) -> [ModelInfo] {
        lock.lock()
        defer { lock.unlock() }
        return models.values.filter { $0.provider == provider }.sorted { $0.name < $1.name }
    }

    /// List all known providers.
    public func providers() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(models.values.map(\.provider))).sorted()
    }

    /// List all registered models.
    public func allModels() -> [ModelInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(models.values).sorted { $0.name < $1.name }
    }

    // MARK: - Registration

    /// Register or update a model.
    public func register(_ model: ModelInfo) {
        lock.lock()
        defer { lock.unlock() }
        models[key(provider: model.provider, id: model.id)] = model
    }

    /// Register multiple models at once.
    public func register(_ newModels: [ModelInfo]) {
        lock.lock()
        defer { lock.unlock() }
        for model in newModels {
            models[key(provider: model.provider, id: model.id)] = model
        }
    }

    // MARK: - Usage Calculator

    /// Calculate the estimated cost for a given model's token usage.
    public func estimateCost(provider: String, modelId: String, promptTokens: Int, completionTokens: Int) -> Double {
        guard let model = model(provider: provider, id: modelId),
              let pricing = model.pricing else {
            // Fallback to CostCalculator's existing logic
            let multipliers = CostCalculator.fallbackMultipliers(for: modelId)
            return CostCalculator.calculateCost(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                inputMultiplier: multipliers.input,
                outputMultiplier: multipliers.output
            )
        }
        return pricing.cost(promptTokens: promptTokens, completionTokens: completionTokens)
    }

    // MARK: - Private

    private func key(provider: String, id: String) -> String {
        "\(provider):\(id)"
    }

    /// Register bundled default models.
    private func registerDefaults() {
        let defaults: [ModelInfo] = [
            // OpenAI
            ModelInfo(id: "gpt-4.1", name: "GPT-4.1", provider: "openai",
                      supportsImages: true, contextWindow: 1_047_576, maxOutputTokens: 32_768,
                      pricing: .init(inputPerMillion: 2.00, outputPerMillion: 8.00)),
            ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 Mini", provider: "openai",
                      supportsImages: true, contextWindow: 1_047_576, maxOutputTokens: 32_768,
                      pricing: .init(inputPerMillion: 0.40, outputPerMillion: 1.60)),
            ModelInfo(id: "gpt-4.1-nano", name: "GPT-4.1 Nano", provider: "openai",
                      supportsImages: true, contextWindow: 1_047_576, maxOutputTokens: 32_768,
                      pricing: .init(inputPerMillion: 0.10, outputPerMillion: 0.40)),
            ModelInfo(id: "gpt-4o", name: "GPT-4o", provider: "openai",
                      supportsImages: true, contextWindow: 128_000, maxOutputTokens: 16_384,
                      pricing: .init(inputPerMillion: 2.50, outputPerMillion: 10.00)),
            ModelInfo(id: "gpt-4o-mini", name: "GPT-4o Mini", provider: "openai",
                      supportsImages: true, contextWindow: 128_000, maxOutputTokens: 16_384,
                      pricing: .init(inputPerMillion: 0.15, outputPerMillion: 0.60)),
            ModelInfo(id: "o4-mini", name: "o4-mini", provider: "openai",
                      supportsReasoning: true, supportsImages: true, contextWindow: 200_000, maxOutputTokens: 100_000,
                      pricing: .init(inputPerMillion: 1.10, outputPerMillion: 4.40)),
            ModelInfo(id: "o3", name: "o3", provider: "openai",
                      supportsReasoning: true, supportsImages: true, contextWindow: 200_000, maxOutputTokens: 100_000,
                      pricing: .init(inputPerMillion: 10.00, outputPerMillion: 40.00)),
            ModelInfo(id: "o3-mini", name: "o3-mini", provider: "openai",
                      supportsReasoning: true, contextWindow: 200_000, maxOutputTokens: 100_000,
                      pricing: .init(inputPerMillion: 1.10, outputPerMillion: 4.40)),

            // Anthropic
            ModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4", provider: "anthropic",
                      supportsReasoning: true, supportsImages: true, contextWindow: 200_000, maxOutputTokens: 64_000,
                      pricing: .init(inputPerMillion: 3.00, outputPerMillion: 15.00)),
            ModelInfo(id: "claude-opus-4-20250514", name: "Claude Opus 4", provider: "anthropic",
                      supportsReasoning: true, supportsImages: true, contextWindow: 200_000, maxOutputTokens: 32_000,
                      pricing: .init(inputPerMillion: 15.00, outputPerMillion: 75.00)),
            ModelInfo(id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", provider: "anthropic",
                      supportsImages: true, contextWindow: 200_000, maxOutputTokens: 8_192,
                      pricing: .init(inputPerMillion: 0.80, outputPerMillion: 4.00)),

            // Google
            ModelInfo(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", provider: "google",
                      supportsReasoning: true, supportsImages: true, contextWindow: 1_000_000, maxOutputTokens: 65_536,
                      pricing: .init(inputPerMillion: 1.25, outputPerMillion: 10.00)),
            ModelInfo(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", provider: "google",
                      supportsReasoning: true, supportsImages: true, contextWindow: 1_000_000, maxOutputTokens: 65_536,
                      pricing: .init(inputPerMillion: 0.15, outputPerMillion: 0.60)),

            // xAI
            ModelInfo(id: "grok-3", name: "Grok 3", provider: "xai",
                      supportsImages: true, contextWindow: 131_072, maxOutputTokens: 131_072,
                      pricing: .init(inputPerMillion: 3.00, outputPerMillion: 15.00)),

            // DeepSeek
            ModelInfo(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", provider: "deepseek",
                      supportsReasoning: true, contextWindow: 128_000, maxOutputTokens: 32_768,
                      pricing: .init(inputPerMillion: 0.55, outputPerMillion: 2.19)),
            ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", provider: "deepseek",
                      supportsReasoning: true, supportsImages: true, contextWindow: 128_000, maxOutputTokens: 32_768,
                      pricing: .init(inputPerMillion: 0.27, outputPerMillion: 1.10)),
        ]

        register(defaults)
    }
}

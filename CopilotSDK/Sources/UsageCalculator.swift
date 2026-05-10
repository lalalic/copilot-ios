import Foundation

// MARK: - UsageCalculator

/// Client-side cost calculation replacing relay-injected cost fields.
/// Derives cost from provider usage payloads plus model pricing metadata.
public final class UsageCalculator: @unchecked Sendable {

    private let modelRegistry: ModelRegistry
    private let lock = NSLock()

    /// Accumulated session usage.
    private var sessionUsage: [String: AccumulatedUsage] = [:]

    public init(modelRegistry: ModelRegistry) {
        self.modelRegistry = modelRegistry
    }

    // MARK: - Usage Tracking

    public struct AccumulatedUsage: Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var estimatedCost: Double

        public init(promptTokens: Int = 0, completionTokens: Int = 0, estimatedCost: Double = 0) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.estimatedCost = estimatedCost
        }
    }

    /// Flat platform fee: $1 per 1M tokens (all types).
    private static let platformFeePerToken: Double = 1.0 / 1_000_000.0

    /// Record usage from a provider response and return the estimated cost.
    @discardableResult
    public func record(provider: String, modelId: String, promptTokens: Int, completionTokens: Int, providerCost: Double? = nil) -> Double {
        // Flat platform fee: $1/1M tokens regardless of model or token type
        let totalTokens = promptTokens + completionTokens
        let cost = Double(totalTokens) * Self.platformFeePerToken

        lock.lock()
        let key = "\(provider):\(modelId)"
        var usage = sessionUsage[key] ?? AccumulatedUsage()
        usage.promptTokens += promptTokens
        usage.completionTokens += completionTokens
        usage.estimatedCost += cost
        sessionUsage[key] = usage
        lock.unlock()

        return cost
    }

    /// Get accumulated usage for a specific model.
    public func usage(provider: String, modelId: String) -> AccumulatedUsage {
        lock.lock()
        defer { lock.unlock() }
        return sessionUsage["\(provider):\(modelId)"] ?? AccumulatedUsage()
    }

    /// Get total session usage across all models.
    public func totalSessionUsage() -> AccumulatedUsage {
        lock.lock()
        defer { lock.unlock() }
        var total = AccumulatedUsage()
        for usage in sessionUsage.values {
            total.promptTokens += usage.promptTokens
            total.completionTokens += usage.completionTokens
            total.estimatedCost += usage.estimatedCost
        }
        return total
    }

    /// Get per-model usage breakdown.
    public func usageByModel() -> [String: AccumulatedUsage] {
        lock.lock()
        defer { lock.unlock() }
        return sessionUsage
    }

    /// Reset session usage counters.
    public func resetSession() {
        lock.lock()
        defer { lock.unlock() }
        sessionUsage.removeAll()
    }

    /// Create a RuntimeEvent.UsageUpdate from provider response data.
    public func createUsageEvent(
        provider: String,
        modelId: String,
        promptTokens: Int,
        completionTokens: Int,
        providerCost: Double? = nil
    ) -> RuntimeEvent.UsageUpdate {
        let cost = record(
            provider: provider,
            modelId: modelId,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            providerCost: providerCost
        )
        return RuntimeEvent.UsageUpdate(
            model: modelId,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost
        )
    }
}

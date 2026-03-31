import Foundation

// MARK: - CostCalculator

/// Calculates token costs using GitHub Models pricing.
/// Base unit: $0.00001 per token unit, multiplied by per-model input/output multipliers.
public enum CostCalculator {
    
    public struct Multipliers: Sendable {
        public let input: Double
        public let output: Double
        
        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
        }
    }
    
    /// Hardcoded fallback multipliers for when the API is unavailable.
    public static let fallbacks: [String: Multipliers] = [
        "gpt-4.1":         Multipliers(input: 0.20, output: 0.80),
        "gpt-4.1-mini":    Multipliers(input: 0.04, output: 0.16),
        "gpt-4.1-nano":    Multipliers(input: 0.01, output: 0.04),
        "gpt-4o":          Multipliers(input: 0.25, output: 1.00),
        "gpt-4o-mini":     Multipliers(input: 0.015, output: 0.06),
        "o4-mini":         Multipliers(input: 0.11, output: 0.44),
        "o3":              Multipliers(input: 1.00, output: 4.00),
        "o3-mini":         Multipliers(input: 0.11, output: 0.44),
        "DeepSeek-R1":     Multipliers(input: 0.135, output: 0.54),
        "Grok-3":          Multipliers(input: 0.30, output: 1.50),
        "Claude-Sonnet-4": Multipliers(input: 0.30, output: 1.50),
        "Claude-Opus-4":   Multipliers(input: 1.50, output: 7.50),
    ]
    
    /// Base cost per token unit in USD.
    public static let baseUnitCost: Double = 0.00001
    
    /// Look up fallback multipliers for a model ID.
    /// First tries exact match, then fuzzy (substring) match, then defaults to gpt-4o.
    public static func fallbackMultipliers(for model: String) -> (input: Double, output: Double) {
        // Exact match
        if let m = fallbacks[model] {
            return (m.input, m.output)
        }
        // Fuzzy match: check if model string contains a known key
        for (key, m) in fallbacks where model.lowercased().contains(key.lowercased()) {
            return (m.input, m.output)
        }
        // Default to gpt-4o
        return (0.25, 1.00)
    }
    
    /// Calculate cost for a given number of tokens.
    public static func calculateCost(
        promptTokens: Int,
        completionTokens: Int,
        inputMultiplier: Double,
        outputMultiplier: Double
    ) -> Double {
        (Double(promptTokens) * inputMultiplier + Double(completionTokens) * outputMultiplier) * baseUnitCost
    }
    
    /// Format a cost as a string with appropriate precision.
    public static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}

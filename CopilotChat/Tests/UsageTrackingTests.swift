import Foundation
import Testing
@testable import CopilotChat
@testable import CopilotSDK

// MARK: - CostCalculator Tests

@Suite("CostCalculator")
struct CostCalculatorTests {
    
    @Test("fallback multipliers for known model")
    func fallbackMultipliersKnownModel() {
        let (input, output) = CostCalculator.fallbackMultipliers(for: "gpt-4.1")
        #expect(input == 0.20)
        #expect(output == 0.80)
    }
    
    @Test("fallback multipliers for gpt-4o-mini")
    func fallbackMultipliersGPT4oMini() {
        let (input, output) = CostCalculator.fallbackMultipliers(for: "gpt-4o-mini")
        #expect(input == 0.015)
        #expect(output == 0.06)
    }
    
    @Test("fallback multipliers for unknown model defaults to gpt-4o")
    func fallbackMultipliersUnknown() {
        let (input, output) = CostCalculator.fallbackMultipliers(for: "totally-unknown-model")
        #expect(input == 0.25)
        #expect(output == 1.00)
    }
    
    @Test("fallback uses fuzzy match for model name variants")
    func fallbackFuzzyMatch() {
        // "openai/gpt-4.1" should match "gpt-4.1"
        let (input, output) = CostCalculator.fallbackMultipliers(for: "openai/gpt-4.1")
        #expect(input == 0.20)
        #expect(output == 0.80)
    }
    
    @Test("cost calculation: 1000 input + 500 output on gpt-4.1")
    func costCalculation() {
        let cost = CostCalculator.calculateCost(
            promptTokens: 1000,
            completionTokens: 500,
            inputMultiplier: 0.20,
            outputMultiplier: 0.80
        )
        // (1000 * 0.20 + 500 * 0.80) * 0.00001 = (200 + 400) * 0.00001 = 0.006
        #expect(abs(cost - 0.006) < 0.000001)
    }
    
    @Test("cost calculation with zero tokens")
    func costCalculationZero() {
        let cost = CostCalculator.calculateCost(
            promptTokens: 0,
            completionTokens: 0,
            inputMultiplier: 0.20,
            outputMultiplier: 0.80
        )
        #expect(cost == 0.0)
    }
    
    @Test("formatCost small amount shows 4 decimals")
    func formatCostSmall() {
        let result = CostCalculator.formatCost(0.006)
        #expect(result == "$0.0060")
    }
    
    @Test("formatCost larger amount shows 2 decimals")
    func formatCostLarger() {
        let result = CostCalculator.formatCost(1.50)
        #expect(result == "$1.50")
    }
    
    @Test("formatCost exactly at threshold (0.01)")
    func formatCostThreshold() {
        let result = CostCalculator.formatCost(0.01)
        #expect(result == "$0.01")
    }
}

// MARK: - UsageTracker Tests

@Suite("UsageTracker")
struct UsageTrackerTests {
    
    @Test("initial balance is $2.00 for new install")
    @MainActor
    func initialBalance() {
        let tracker = UsageTracker(defaults: .makeFresh())
        #expect(tracker.balance == 2.00)
    }
    
    @Test("record usage deducts from balance")
    @MainActor
    func recordDeductsBalance() {
        let tracker = UsageTracker(defaults: .makeFresh())
        
        tracker.record(
            model: "gpt-4.1",
            promptTokens: 1000,
            completionTokens: 500,
            cost: 0.006
        )
        
        #expect(abs(tracker.balance - (2.00 - 0.006)) < 0.000001)
        #expect(abs(tracker.sessionCost - 0.006) < 0.000001)
        #expect(tracker.sessionTokens == 1500)
    }
    
    @Test("record usage accumulates across multiple calls")
    @MainActor
    func recordAccumulates() {
        let tracker = UsageTracker(defaults: .makeFresh())
        
        tracker.record(model: "gpt-4.1", promptTokens: 100, completionTokens: 50, cost: 0.0006)
        tracker.record(model: "gpt-4.1", promptTokens: 200, completionTokens: 100, cost: 0.0012)
        
        #expect(tracker.sessionTokens == 450) // 150 + 300
        #expect(tracker.lifetimeTokens == 450)
    }
    
    @Test("balance never goes below zero")
    @MainActor
    func balanceFloor() {
        let tracker = UsageTracker(defaults: .makeFresh())
        
        // Drain balance with a huge request
        tracker.record(model: "o3", promptTokens: 1_000_000, completionTokens: 1_000_000, cost: 50.00)
        
        #expect(tracker.balance == 0.0)
    }
    
    @Test("addCredits increases balance")
    @MainActor
    func addCredits() {
        let tracker = UsageTracker(defaults: .makeFresh())
        tracker.addCredits(3.50)
        #expect(tracker.balance == 5.50) // 2.00 + 3.50
    }
    
    @Test("resetSession clears session counters but keeps lifetime")
    @MainActor
    func resetSession() {
        let tracker = UsageTracker(defaults: .makeFresh())
        
        tracker.record(model: "gpt-4.1", promptTokens: 1000, completionTokens: 500, cost: 0.006)
        
        let lifetimeBefore = tracker.lifetimeTokens
        tracker.resetSession()
        
        #expect(tracker.sessionCost == 0)
        #expect(tracker.sessionTokens == 0)
        #expect(tracker.lifetimeTokens == lifetimeBefore)
    }
    
    @Test("persist and restore balance")
    @MainActor
    func persistAndRestore() {
        let defaults = UserDefaults.makeFresh()
        
        // Create tracker, use some tokens
        let tracker1 = UsageTracker(defaults: defaults)
        tracker1.record(model: "gpt-4.1", promptTokens: 1000, completionTokens: 500, cost: 0.006)
        let savedBalance = tracker1.balance
        let savedLifetimeCost = tracker1.lifetimeCost
        
        // Create new tracker with same defaults — should restore
        let tracker2 = UsageTracker(defaults: defaults)
        #expect(tracker2.balance == savedBalance)
        #expect(tracker2.lifetimeCost == savedLifetimeCost)
    }
    
    @Test("per-model breakdown tracks correctly")
    @MainActor
    func perModelBreakdown() {
        let tracker = UsageTracker(defaults: .makeFresh())
        
        tracker.record(model: "gpt-4.1", promptTokens: 100, completionTokens: 50, cost: 0.0006)
        tracker.record(model: "gpt-4o-mini", promptTokens: 200, completionTokens: 100, cost: 0.00009)
        
        #expect(tracker.sessionUsageByModel.count == 2)
        #expect(tracker.sessionUsageByModel["gpt-4.1"]?.promptTokens == 100)
        #expect(tracker.sessionUsageByModel["gpt-4o-mini"]?.promptTokens == 200)
    }
    
    @Test("hasInsufficientBalance when balance is zero")
    @MainActor
    func insufficientBalance() {
        let defaults = UserDefaults.makeFresh()
        defaults.set(0.0, forKey: "neox.balance")
        let tracker = UsageTracker(defaults: defaults)
        #expect(tracker.hasInsufficientBalance)
    }
    
    @Test("isLowBalance when balance below threshold")
    @MainActor
    func lowBalance() {
        let defaults = UserDefaults.makeFresh()
        defaults.set(0.30, forKey: "neox.balance")
        let tracker = UsageTracker(defaults: defaults)
        #expect(tracker.isLowBalance)
    }
}

// MARK: - JSONValue Accessor Tests

@Suite("JSONValue Accessors")
struct JSONValueAccessorTests {
    
    @Test("stringValue extracts string")
    func stringValue() {
        let val = JSONValue.string("hello")
        #expect(val.stringValue == "hello")
    }
    
    @Test("intValue extracts int")
    func intValue() {
        let val = JSONValue.int(42)
        #expect(val.intValue == 42)
    }
    
    @Test("intValue returns nil for string")
    func intValueNilForString() {
        let val = JSONValue.string("not a number")
        #expect(val.intValue == nil)
    }
    
    @Test("subscript accesses object keys")
    func subscriptObject() {
        let val = JSONValue.object(["model": .string("gpt-4.1"), "tokens": .int(100)])
        #expect(val["model"]?.stringValue == "gpt-4.1")
        #expect(val["tokens"]?.intValue == 100)
    }
    
    @Test("subscript returns nil for non-object")
    func subscriptNonObject() {
        let val = JSONValue.string("not an object")
        #expect(val["key"] == nil)
    }
}

// MARK: - Helper

extension UserDefaults {
    static func makeFresh() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

import Testing
import Foundation
@testable import CopilotChat
@testable import CopilotSDK

// MARK: - Model Info Tests

@Suite("Model Info")
struct ModelInfoTests {
    
    @Test("ModelInfo initializes correctly")
    func modelInfoInit() {
        let model = ModelInfo(
            id: "test-model",
            name: "Test Model",
            family: "TestFamily",
            tier: .balanced,
            inputMultiplier: 0.20,
            outputMultiplier: 0.80,
            description: "Test description"
        )
        
        #expect(model.id == "test-model")
        #expect(model.name == "Test Model")
        #expect(model.family == "TestFamily")
        #expect(model.tier == .balanced)
        #expect(model.inputMultiplier == 0.20)
        #expect(model.outputMultiplier == 0.80)
        #expect(model.description == "Test description")
    }
    
    @Test("ModelInfo costPer100K calculation")
    func costPer100KCalculation() {
        // Using known multipliers from GPT-4.1: input=0.20, output=0.80
        // costPer100K = (50_000 * 0.20 + 50_000 * 0.80) * baseUnitCost
        // = 50_000 * (0.20 + 0.80) * baseUnitCost = 50_000 * 1.0 * 0.00001 = 0.50
        let model = ModelInfo(
            id: "test",
            name: "Test",
            family: "Test",
            tier: .balanced,
            inputMultiplier: 0.20,
            outputMultiplier: 0.80,
            description: "Test"
        )
        
        let expected = (50_000 * 0.20 + 50_000 * 0.80) * CostCalculator.baseUnitCost
        #expect(abs(model.costPer100K - expected) < 0.0001)
    }
    
    @Test("ModelInfo is Hashable")
    func modelInfoHashable() {
        let model1 = ModelInfo(id: "m1", name: "M1", family: "F", tier: .fast,
                               inputMultiplier: 0.1, outputMultiplier: 0.1, description: "D")
        let model2 = ModelInfo(id: "m1", name: "M1", family: "F", tier: .fast,
                               inputMultiplier: 0.1, outputMultiplier: 0.1, description: "D")
        let model3 = ModelInfo(id: "m2", name: "M2", family: "F", tier: .fast,
                               inputMultiplier: 0.1, outputMultiplier: 0.1, description: "D")
        
        #expect(model1 == model2)
        #expect(model1 != model3)
        
        var set = Set<ModelInfo>()
        set.insert(model1)
        set.insert(model2)
        #expect(set.count == 1)
    }
}

// MARK: - Model Tier Tests

@Suite("Model Tier")
struct ModelTierTests {
    
    @Test("ModelTier has correct raw values")
    func tierRawValues() {
        #expect(ModelTier.fast.rawValue == "Fast & Cheap")
        #expect(ModelTier.balanced.rawValue == "Balanced")
        #expect(ModelTier.powerful.rawValue == "Powerful")
        #expect(ModelTier.reasoning.rawValue == "Reasoning")
    }
    
    @Test("ModelTier allCases contains all tiers")
    func tierAllCases() {
        let all = ModelTier.allCases
        #expect(all.count == 4)
        #expect(all.contains(.fast))
        #expect(all.contains(.balanced))
        #expect(all.contains(.powerful))
        #expect(all.contains(.reasoning))
    }
}

// MARK: - Model Catalog Tests

@Suite("Model Catalog")
struct ModelCatalogTests {
    
    @Test("Catalog contains models")
    func catalogHasModels() {
        #expect(!ModelCatalog.allModels.isEmpty)
        #expect(ModelCatalog.allModels.count >= 12)
    }
    
    @Test("Catalog contains expected models")
    func catalogContainsKnownModels() {
        let ids = Set(ModelCatalog.allModels.map { $0.id })
        #expect(ids.contains("gpt-4.1"))
        #expect(ids.contains("gpt-4o-mini"))
        #expect(ids.contains("gpt-4.1-nano"))
        #expect(ids.contains("Claude-Sonnet-4"))
        #expect(ids.contains("Claude-Opus-4"))
    }
    
    @Test("model(for:) finds existing model")
    func modelForIdFound() {
        let model = ModelCatalog.model(for: "gpt-4.1")
        #expect(model != nil)
        #expect(model?.name == "GPT-4.1")
        #expect(model?.tier == .balanced)
    }
    
    @Test("model(for:) returns nil for unknown ID")
    func modelForIdNotFound() {
        let model = ModelCatalog.model(for: "unknown-model-xyz")
        #expect(model == nil)
    }
    
    @Test("byTier groups models correctly")
    func byTierGrouping() {
        let grouped = ModelCatalog.byTier
        
        // Should have entries for non-empty tiers
        #expect(!grouped.isEmpty)
        
        // Each tier's models should all have matching tier
        for (tier, models) in grouped {
            for model in models {
                #expect(model.tier == tier)
            }
        }
    }
    
    @Test("All models have unique IDs")
    func uniqueModelIds() {
        let ids = ModelCatalog.allModels.map { $0.id }
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }
    
    @Test("All models have non-empty names and descriptions")
    func modelsHaveRequiredFields() {
        for model in ModelCatalog.allModels {
            #expect(!model.id.isEmpty)
            #expect(!model.name.isEmpty)
            #expect(!model.family.isEmpty)
            #expect(!model.description.isEmpty)
            #expect(model.inputMultiplier > 0)
            #expect(model.outputMultiplier > 0)
        }
    }
    
    @Test("Fast tier models are cheapest")
    func fastTierCheapest() {
        let fastModels = ModelCatalog.allModels.filter { $0.tier == .fast }
        let powerfulModels = ModelCatalog.allModels.filter { $0.tier == .powerful }
        
        guard let cheapestFast = fastModels.min(by: { $0.costPer100K < $1.costPer100K }),
              let cheapestPowerful = powerfulModels.min(by: { $0.costPer100K < $1.costPer100K }) else {
            Issue.record("Missing models in tiers")
            return
        }
        
        #expect(cheapestFast.costPer100K < cheapestPowerful.costPer100K)
    }
}

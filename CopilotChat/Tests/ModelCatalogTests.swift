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
            multiplier: 1,
            description: "Test description"
        )
        
        #expect(model.id == "test-model")
        #expect(model.name == "Test Model")
        #expect(model.family == "TestFamily")
        #expect(model.tier == .balanced)
        #expect(model.multiplier == 1)
        #expect(model.description == "Test description")
    }
    
    @Test("ModelInfo multiplierLabel formatting")
    func multiplierLabelFormatting() {
        let free = ModelInfo(id: "t1", name: "T", family: "F", tier: .fast,
                             multiplier: 0, description: "D")
        #expect(free.multiplierLabel == "Free")
        
        let fractional = ModelInfo(id: "t2", name: "T", family: "F", tier: .fast,
                                   multiplier: 0.33, description: "D")
        #expect(fractional.multiplierLabel == "0.33x")
        
        let standard = ModelInfo(id: "t3", name: "T", family: "F", tier: .powerful,
                                 multiplier: 1, description: "D")
        #expect(standard.multiplierLabel == "1x")
        
        let premium = ModelInfo(id: "t4", name: "T", family: "F", tier: .powerful,
                                multiplier: 3, description: "D")
        #expect(premium.multiplierLabel == "3x")
    }
    
    @Test("ModelInfo is Hashable")
    func modelInfoHashable() {
        let model1 = ModelInfo(id: "m1", name: "M1", family: "F", tier: .fast,
                               multiplier: 0, description: "D")
        let model2 = ModelInfo(id: "m1", name: "M1", family: "F", tier: .fast,
                               multiplier: 0, description: "D")
        let model3 = ModelInfo(id: "m2", name: "M2", family: "F", tier: .fast,
                               multiplier: 0, description: "D")
        
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
            #expect(model.multiplier >= 0)
        }
    }
    
    @Test("Fast tier models have lowest multipliers")
    func fastTierCheapest() {
        let fastModels = ModelCatalog.allModels.filter { $0.tier == .fast }
        let powerfulModels = ModelCatalog.allModels.filter { $0.tier == .powerful }
        
        guard let maxFast = fastModels.max(by: { $0.multiplier < $1.multiplier }),
              let minPowerful = powerfulModels.min(by: { $0.multiplier < $1.multiplier }) else {
            Issue.record("Missing models in tiers")
            return
        }
        
        #expect(maxFast.multiplier <= minPowerful.multiplier)
    }
}

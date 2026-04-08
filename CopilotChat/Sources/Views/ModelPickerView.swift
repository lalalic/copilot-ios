import SwiftUI
import CopilotSDK

// MARK: - Model Info

/// A selectable LLM model with pricing information.
/// Multiplier values match `relay/lib/models.json` (billing.multiplier from GitHub Copilot API).
public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: String          // e.g., "gpt-4.1"
    public let name: String        // Display name
    public let family: String      // "OpenAI", "Anthropic", "xAI", "DeepSeek"
    public let tier: ModelTier
    public let multiplier: Double  // Premium request multiplier (0 = free/included)
    public let description: String
    
    public init(id: String, name: String, family: String, tier: ModelTier,
                multiplier: Double, description: String) {
        self.id = id
        self.name = name
        self.family = family
        self.tier = tier
        self.multiplier = multiplier
        self.description = description
    }
    
    /// Display string for the multiplier, e.g. "1x", "3x", or "Free".
    public var multiplierLabel: String {
        if multiplier <= 0 {
            return "Free"
        } else if multiplier < 1.0 {
            return String(format: "%.2fx", multiplier)
        } else {
            return String(format: "%.0fx", multiplier)
        }
    }
}

/// Model tiers for grouping and display.
public enum ModelTier: String, CaseIterable, Hashable, Sendable {
    case fast = "Fast & Cheap"
    case balanced = "Balanced"
    case powerful = "Powerful"
    case reasoning = "Reasoning"
}

// MARK: - Model Catalog (Static)

/// Hardcoded model catalog. Multipliers from relay/lib/models.json (GitHub Copilot billing).
public enum ModelCatalog {
    public static let allModels: [ModelInfo] = [
        // Fast & Cheap (multiplier 0 = free/included)
        ModelInfo(id: "gpt-4.1-nano", name: "GPT-4.1 Nano", family: "OpenAI", tier: .fast,
                  multiplier: 0, description: "Fastest, cheapest. Good for simple tasks."),
        ModelInfo(id: "gpt-4o-mini", name: "GPT-4o Mini", family: "OpenAI", tier: .fast,
                  multiplier: 0, description: "Fast multimodal model, great for quick tasks."),
        ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 Mini", family: "OpenAI", tier: .fast,
                  multiplier: 0, description: "Cost-effective for coding and analysis."),
        
        // Balanced
        ModelInfo(id: "gpt-4.1", name: "GPT-4.1", family: "OpenAI", tier: .balanced,
                  multiplier: 0, description: "Best all-around model. Great for coding."),
        ModelInfo(id: "gpt-4o", name: "GPT-4o", family: "OpenAI", tier: .balanced,
                  multiplier: 0, description: "Strong multimodal with vision capabilities."),
        ModelInfo(id: "DeepSeek-R1", name: "DeepSeek R1", family: "DeepSeek", tier: .balanced,
                  multiplier: 0.33, description: "Open-source reasoning model."),
        
        // Powerful
        ModelInfo(id: "Claude-Sonnet-4", name: "Claude Sonnet 4", family: "Anthropic", tier: .powerful,
                  multiplier: 1, description: "Excellent writing and analysis."),
        ModelInfo(id: "Grok-3", name: "Grok 3", family: "xAI", tier: .powerful,
                  multiplier: 1, description: "xAI's flagship model."),
        ModelInfo(id: "Claude-Opus-4", name: "Claude Opus 4", family: "Anthropic", tier: .powerful,
                  multiplier: 3, description: "Most capable Claude. Premium quality."),
        
        // Reasoning
        ModelInfo(id: "o4-mini", name: "o4-mini", family: "OpenAI", tier: .reasoning,
                  multiplier: 0.33, description: "Fast reasoning with chain-of-thought."),
        ModelInfo(id: "o3-mini", name: "o3-mini", family: "OpenAI", tier: .reasoning,
                  multiplier: 0.33, description: "Compact reasoning model."),
        ModelInfo(id: "o3", name: "o3", family: "OpenAI", tier: .reasoning,
                  multiplier: 1, description: "Most powerful reasoning. Deep analysis."),
    ]
    
    /// Find a model by ID.
    public static func model(for id: String) -> ModelInfo? {
        allModels.first { $0.id == id }
    }
    
    /// Models grouped by tier.
    public static var byTier: [(tier: ModelTier, models: [ModelInfo])] {
        ModelTier.allCases.compactMap { tier in
            let models = allModels.filter { $0.tier == tier }
            return models.isEmpty ? nil : (tier, models)
        }
    }
}

// MARK: - Model Picker View

/// A settings view for selecting the LLM model.
public struct ModelPickerView: View {
    @Binding var selectedModelId: String
    var onModelChanged: ((String) -> Void)?
    
    public init(selectedModelId: Binding<String>, onModelChanged: ((String) -> Void)? = nil) {
        self._selectedModelId = selectedModelId
        self.onModelChanged = onModelChanged
    }
    
    public var body: some View {
        List {
            ForEach(ModelCatalog.byTier, id: \.tier) { group in
                Section(group.tier.rawValue) {
                    ForEach(group.models) { model in
                        ModelRowView(
                            model: model,
                            isSelected: model.id == selectedModelId
                        ) {
                            selectedModelId = model.id
                            onModelChanged?(model.id)
                        }
                    }
                }
            }
            
            Section {
                HStack {
                    Spacer()
                    Text("Higher multiplier = more capable, more expensive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Model Row

private struct ModelRowView: View {
    let model: ModelInfo
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(model.name)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Text(model.multiplierLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Model Badge

/// A small badge showing the current model name, tappable for picker.
public struct ModelBadgeView: View {
    let modelId: String
    let action: () -> Void
    
    public init(modelId: String, action: @escaping () -> Void) {
        self.modelId = modelId
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(displayName)
                    .font(.caption2)
                    .fontWeight(.medium)
                Text(model?.multiplierLabel ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
    }
    
    private var model: ModelInfo? {
        ModelCatalog.model(for: modelId)
    }
    
    private var displayName: String {
        model?.name ?? modelId
    }
}

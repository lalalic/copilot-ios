import SwiftUI
import CopilotSDK

// MARK: - Model Info

/// A selectable LLM model with pricing information.
public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: String          // e.g., "gpt-4.1"
    public let name: String        // Display name
    public let family: String      // "OpenAI", "Anthropic", "xAI", "DeepSeek"
    public let tier: ModelTier
    public let description: String
    public let supportsImages: Bool
    
    public init(id: String, name: String, family: String, tier: ModelTier,
                description: String, supportsImages: Bool = true) {
        self.id = id
        self.name = name
        self.family = family
        self.tier = tier
        self.description = description
        self.supportsImages = supportsImages
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

/// Hardcoded model catalog. IDs match ModelRegistry for consistent lookup.
public enum ModelCatalog {
    public static let allModels: [ModelInfo] = [
        // Fast & Cheap
        ModelInfo(id: "gpt-4.1-nano", name: "GPT-4.1 Nano", family: "OpenAI", tier: .fast,
                  description: "Fastest, cheapest. Good for simple tasks."),
        ModelInfo(id: "gpt-4o-mini", name: "GPT-4o Mini", family: "OpenAI", tier: .fast,
                  description: "Fast multimodal model, great for quick tasks."),
        ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 Mini", family: "OpenAI", tier: .fast,
                  description: "Cost-effective for coding and analysis."),
        ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", family: "DeepSeek", tier: .fast,
                  description: "Fast and capable. Default model."),
        
        // Balanced
        ModelInfo(id: "gpt-4.1", name: "GPT-4.1", family: "OpenAI", tier: .balanced,
                  description: "Best all-around model. Great for coding."),
        ModelInfo(id: "gpt-4o", name: "GPT-4o", family: "OpenAI", tier: .balanced,
                  description: "Strong multimodal with vision capabilities."),
        ModelInfo(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", family: "DeepSeek", tier: .balanced,
                  description: "DeepSeek's most capable model."),
        
        // Powerful
        ModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4", family: "Anthropic", tier: .powerful,
                  description: "Excellent writing and analysis."),
        ModelInfo(id: "grok-3", name: "Grok 3", family: "xAI", tier: .powerful,
                  description: "xAI's flagship model."),
        ModelInfo(id: "claude-opus-4-20250514", name: "Claude Opus 4", family: "Anthropic", tier: .powerful,
                  description: "Most capable Claude. Premium quality."),
        
        // Reasoning
        ModelInfo(id: "o4-mini", name: "o4-mini", family: "OpenAI", tier: .reasoning,
                  description: "Fast reasoning with chain-of-thought."),
        ModelInfo(id: "o3-mini", name: "o3-mini", family: "OpenAI", tier: .reasoning,
                  description: "Compact reasoning model."),
        ModelInfo(id: "o3", name: "o3", family: "OpenAI", tier: .reasoning,
                  description: "Most powerful reasoning. Deep analysis."),

        // Relay (zero-config OpenAI-compatible endpoint at relay.ai.qili2.com,
        // billed through the platform credit account instead of a per-provider
        // API key). Currently only DeepSeek is exposed.
        ModelInfo(id: "deepseek-v4-flash", name: "Flash", family: "relay", tier: .fast,
                  description: "DeepSeek V4 Flash via Relay."),
        ModelInfo(id: "deepseek-v4-pro", name: "Pro", family: "relay", tier: .balanced,
                  description: "DeepSeek V4 Pro via Relay."),
    ]
    
    /// Find a model by ID.
    public static func model(for id: String) -> ModelInfo? {
        allModels.first { $0.id == id }
    }

    /// Find a model by ID and provider family.
    public static func model(for id: String, family: String) -> ModelInfo? {
        allModels.first { $0.id == id && $0.family == family }
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
///
/// Pass `models:` to display a per-app dynamic list (typically loaded by
/// `RemoteModelCatalog`). When omitted, falls back to `ModelCatalog.allModels`.
///
/// When `configuredProviders` is set (BYOK / direct mode), only models whose
/// provider has a stored API key are selectable; others are greyed out.
public struct ModelPickerView: View {
    @Binding var selectedModelId: String
    var models: [ModelInfo]
    var configuredProviders: Set<String>?
    var onModelChanged: ((String) -> Void)?

    /// When set, the picker uses these explicit groups (one section per
    /// provider) instead of grouping `models` by tier. Each tuple's `models`
    /// is rendered in order; outer order wins for sections.
    ///
    /// Selection uses a composite id of the form `"<providerId>/<modelId>"`
    /// so the runtime can disambiguate the same model id offered by multiple
    /// providers (e.g. built-in DeepSeek vs. a user-added custom DeepSeek).
    var providerGroups: [(id: String, name: String, models: [ModelInfo])]?

    public init(selectedModelId: Binding<String>,
                models: [ModelInfo] = ModelCatalog.allModels,
                configuredProviders: Set<String>? = nil,
                onModelChanged: ((String) -> Void)? = nil) {
        self._selectedModelId = selectedModelId
        self.models = models
        self.configuredProviders = configuredProviders
        self.onModelChanged = onModelChanged
        self.providerGroups = nil
    }

    /// Provider-grouped variant — used by Neox to render only the user's
    /// enabled models, sectioned by provider. The binding stores the
    /// composite id `"<providerId>/<modelId>"`.
    public init(selectedModelId: Binding<String>,
                providerGroups: [(id: String, name: String, models: [ModelInfo])],
                onModelChanged: ((String) -> Void)? = nil) {
        self._selectedModelId = selectedModelId
        self.models = providerGroups.flatMap(\.models)
        self.configuredProviders = nil
        self.onModelChanged = onModelChanged
        self.providerGroups = providerGroups
    }

    private var byTier: [(tier: ModelTier, models: [ModelInfo])] {
        ModelTier.allCases.compactMap { tier in
            let group = models.filter { $0.tier == tier }
            return group.isEmpty ? nil : (tier, group)
        }
    }

    private func isAvailable(_ model: ModelInfo) -> Bool {
        guard let providers = configuredProviders else { return true }
        return providers.contains(model.family.lowercased())
    }

    public var body: some View {
        List {
            if let groups = providerGroups {
                if groups.isEmpty {
                    Section {
                        Text("No models enabled. Open Settings → Providers and enable at least one model.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(groups, id: \.id) { group in
                        Section(group.name) {
                            ForEach(group.models) { model in
                                let compositeId = "\(group.id)/\(model.id)"
                                ModelRowView(
                                    model: model,
                                    isSelected: compositeId == selectedModelId,
                                    isDisabled: false
                                ) {
                                    selectedModelId = compositeId
                                    onModelChanged?(compositeId)
                                }
                            }
                        }
                    }
                }
            } else {
                ForEach(byTier, id: \.tier) { group in
                    Section(group.tier.rawValue) {
                        ForEach(group.models) { model in
                            let available = isAvailable(model)
                            ModelRowView(
                                model: model,
                                isSelected: model.id == selectedModelId,
                                isDisabled: !available
                            ) {
                                guard available else { return }
                                selectedModelId = model.id
                                onModelChanged?(model.id)
                            }
                        }
                    }
                }

                if configuredProviders != nil {
                    Section {
                        HStack {
                            Spacer()
                            Text("Bring your own API key")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
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
    var isDisabled: Bool = false
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(model.name)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isDisabled ? .tertiary : .primary)
                
                Spacer()

                if isDisabled {
                    Text("Add key")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                
                if isSelected && !isDisabled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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

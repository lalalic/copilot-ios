import SwiftUI

// MARK: - Providers Settings Section

/// Settings section listing every provider known to `ModelCatalog` plus a
/// per-model enable/disable toggle. Embed inside a `Form`.
///
/// `enabledIds` is a binding into the user's enabled-models set
/// (typically `coordinator.enabledModelIds`).
///
/// `configuredProviderFamilies` (lowercase family names) is the set of
/// non-built-in providers for which the user has supplied an API key. CCM
/// Relay is treated as built-in and always enabled regardless.
public struct ProvidersSettingsSection: View {
    @Binding var enabledIds: Set<String>
    var models: [ModelInfo]
    var configuredProviderFamilies: Set<String>
    var onChange: ((String, Bool) -> Void)?

    public init(enabledIds: Binding<Set<String>>,
                models: [ModelInfo] = ModelCatalog.allModels,
                configuredProviderFamilies: Set<String> = [],
                onChange: ((String, Bool) -> Void)? = nil) {
        self._enabledIds = enabledIds
        self.models = models
        self.configuredProviderFamilies = configuredProviderFamilies
        self.onChange = onChange
    }

    private var familyOrder: [String] {
        var seen = Set<String>()
        var out: [String] = []
        // ccm-relay first
        for m in models where m.family.lowercased() == "ccm-relay" && !seen.contains(m.family) {
            out.append(m.family); seen.insert(m.family)
        }
        for m in models where !seen.contains(m.family) {
            out.append(m.family); seen.insert(m.family)
        }
        return out
    }

    public var body: some View {
        ForEach(familyOrder, id: \.self) { family in
            Section {
                if let subtitle = ProviderDisplay.subtitle(for: family) {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                let isBuiltIn = family.lowercased() == "ccm-relay"
                let hasKey = isBuiltIn || configuredProviderFamilies.contains(family.lowercased())
                if !hasKey {
                    Label("Add an API key to enable models", systemImage: "key")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                let group = models.filter { $0.family == family }
                ForEach(group) { model in
                    Toggle(isOn: Binding(
                        get: { enabledIds.contains(model.id) },
                        set: { newValue in
                            if newValue { enabledIds.insert(model.id) }
                            else { enabledIds.remove(model.id) }
                            onChange?(model.id, newValue)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.body)
                            if !model.description.isEmpty {
                                Text(model.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!hasKey)
                }
            } header: {
                HStack {
                    Text(ProviderDisplay.name(for: family))
                    if family.lowercased() == "ccm-relay" {
                        Text("Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }
}

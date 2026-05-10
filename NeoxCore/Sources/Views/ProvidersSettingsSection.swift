import SwiftUI
import CopilotSDK

// MARK: - ProvidersSettingsSection
//
// Replaces the legacy "Direct Provider (BYOK)" section. Lists every
// configured provider (built-ins + user-added), shows enabled/total model
// counts, and links to a per-provider edit view for managing the API key
// and which models appear in the picker.

public struct ProvidersSettingsSection: View {
    @ObservedObject var coordinator: BaseCoordinator
    // Observe the registry directly so per-row mutations (toggles, upserts,
    // deletes) immediately re-render this section. Without this, only the
    // outer BaseCoordinator's @Published properties would trigger updates,
    // and nested ObservableObject changes wouldn't propagate.
    @ObservedObject var registry: ProviderRegistry

    public init(coordinator: BaseCoordinator) {
        self.coordinator = coordinator
        self.registry = coordinator.providerRegistry
    }

    public var body: some View {
        Section {
            ForEach(registry.providers) { p in
                NavigationLink {
                    ProviderEditView(coordinator: coordinator, provider: p)
                } label: {
                    ProviderRow(provider: p, hasApiKey: hasApiKey(for: p))
                }
            }

            NavigationLink {
                ProviderEditView(
                    coordinator: coordinator,
                    provider: ProviderConfig(
                        id: UUID().uuidString,
                        name: "",
                        type: .openaiCompatible,
                        baseUrl: "",
                        models: [],
                        enabledModelIds: [],
                        source: .user
                    ),
                    isNew: true
                )
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
        } header: {
            Text("Providers (\(registry.providers.count))")
        } footer: {
            Text("Relay is built-in and uses your platform credit. Add custom OpenAI-compatible providers (e.g. DeepSeek, OpenRouter) with your own API key.")
                .font(.caption)
        }
    }

    private func hasApiKey(for p: ProviderConfig) -> Bool {
        guard p.requiresApiKey else { return true }
        return (coordinator.credentialStore.getAPIKey(forProviderKey: p.id) ?? "").isEmpty == false
    }
}

private struct ProviderRow: View {
    let provider: ProviderConfig
    let hasApiKey: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name).foregroundColor(.primary)
                    if provider.source == .builtin {
                        Text("BUILT-IN")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let total = provider.models.count
        let on = provider.enabledModelIds.count
        if provider.requiresApiKey, !hasApiKey {
            return "API key not set"
        }
        if total == 0 {
            return provider.requiresApiKey ? "Tap to fetch models" : "No models"
        }
        return "\(on) of \(total) enabled"
    }
}

// MARK: - ProviderEditView

public struct ProviderEditView: View {
    @ObservedObject var coordinator: BaseCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProviderConfig
    @State private var apiKey: String = ""
    @State private var fetching = false
    @State private var fetchError: String? = nil
    @State private var didAutoFetch = false

    private let original: ProviderConfig
    private let isNew: Bool

    public init(coordinator: BaseCoordinator, provider: ProviderConfig, isNew: Bool = false) {
        self.coordinator = coordinator
        self.original = provider
        self.isNew = isNew
        _draft = State(initialValue: provider)
        _apiKey = State(initialValue:
            coordinator.credentialStore.getAPIKey(forProviderKey: provider.id) ?? "")
    }

    public var body: some View {
        Form {
            Section("Provider") {
                if draft.source == .builtin {
                    LabeledContent("Name", value: draft.name)
                    LabeledContent("Type", value: draft.type.displayName)
                } else {
                    TextField("Name", text: $draft.name)
                        .autocorrectionDisabled()
                    Picker("Type", selection: $draft.type) {
                        ForEach(ProviderType.allCases, id: \.self) { t in
                            if t == .openaiCompatible {
                                Text(t.displayName).tag(t)
                            }
                        }
                    }
                }

                if let baseUrl = draft.baseUrl, draft.source == .builtin {
                    LabeledContent("Base URL", value: baseUrl)
                        .lineLimit(1).truncationMode(.middle)
                } else if draft.type != .relay {
                    TextField("Base URL", text: Binding(
                        get: { draft.baseUrl ?? "" },
                        set: { draft.baseUrl = $0 }
                    ))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                }
            }

            if draft.requiresApiKey {
                Section("API Key") {
                    SecureField("sk-…", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } else {
                Section("API Key") {
                    Text("Not required — calls use your platform credit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await fetchModels() }
                } label: {
                    HStack {
                        if fetching { ProgressView().scaleEffect(0.8) }
                        Text(fetching ? "Fetching…" : "Fetch Models from /v1/models")
                    }
                }
                .disabled(fetching || (draft.requiresApiKey && apiKey.isEmpty) || (draft.baseUrl ?? "").isEmpty)

                if let err = fetchError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            if !draft.models.isEmpty {
                Section {
                    ForEach(draft.models) { m in
                        Toggle(isOn: Binding(
                            get: { draft.enabledModelIds.contains(m.id) },
                            set: { on in
                                if on {
                                    if !draft.enabledModelIds.contains(m.id) {
                                        draft.enabledModelIds.append(m.id)
                                    }
                                } else {
                                    draft.enabledModelIds.removeAll { $0 == m.id }
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).font(.body)
                                Text(m.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Models (\(draft.enabledModelIds.count) of \(draft.models.count) enabled)")
                }
            }

            if draft.source != .builtin {
                Section {
                    Button("Delete Provider", role: .destructive) {
                        coordinator.providerRegistry.delete(id: draft.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "New Provider" : draft.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
        #endif
        .task {
            // Auto-populate the model list on first appear when we have
            // enough info to call /v1/models. Skip for relay (models are
            // baked-in) and skip if the user has zero credentials yet.
            guard !didAutoFetch else { return }
            didAutoFetch = true
            if draft.type == .relay { return }
            if (draft.baseUrl ?? "").isEmpty { return }
            if draft.requiresApiKey, apiKey.isEmpty { return }
            await fetchModels()
        }
    }

    private var canSave: Bool {
        if draft.source == .user, draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if draft.requiresApiKey, draft.source == .user, apiKey.isEmpty { return false }
        return true
    }

    private func save() {
        // Store API key in keychain (or remove if cleared)
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.requiresApiKey {
            if trimmed.isEmpty {
                try? coordinator.credentialStore.removeAPIKey(forProviderKey: draft.id)
            } else {
                try? coordinator.credentialStore.setAPIKey(trimmed, forProviderKey: draft.id)
            }
        }
        coordinator.providerRegistry.upsert(draft)
        // Force-flush UserDefaults synchronously so a quick sheet dismissal
        // can't outrun the write.
        UserDefaults.standard.synchronize()
        dismiss()
    }

    private func fetchModels() async {
        fetchError = nil
        fetching = true
        defer { fetching = false }

        guard let baseUrlStr = draft.baseUrl,
              let url = URL(string: baseUrlStr.trimmingCharacters(in: .whitespacesAndNewlines)
                                .appending("/models")) else {
            fetchError = "Invalid base URL"
            return
        }
        var req = URLRequest(url: url)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            req.addValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                fetchError = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            struct Env: Decodable { let data: [Item] }
            struct Item: Decodable { let id: String }
            let env = try JSONDecoder().decode(Env.self, from: data)
            let models = env.data.map { ProviderModel(id: $0.id, name: $0.id) }
                .sorted { $0.name < $1.name }
            draft.models = models
            // Pre-enable everything on first fetch when nothing is enabled
            if draft.enabledModelIds.isEmpty {
                draft.enabledModelIds = models.map(\.id)
            } else {
                let valid = Set(models.map(\.id))
                draft.enabledModelIds = draft.enabledModelIds.filter { valid.contains($0) }
            }
        } catch {
            fetchError = "Fetch failed: \(error.localizedDescription)"
        }
    }
}

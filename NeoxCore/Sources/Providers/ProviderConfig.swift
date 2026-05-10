import Foundation

// MARK: - ProviderConfig
//
// Per-provider configuration used by Neox's Settings UI to drive the
// model picker. There are two built-in providers that can never be deleted:
//
//   - `deepseek`: BYOK (user pastes their own DeepSeek API key)
//   - `relay`: zero-config; all calls billed via the platform's relay credit
//
// Users may add additional `openai-compatible` custom providers (any endpoint
// that exposes `GET {baseUrl}/models` and `POST {baseUrl}/chat/completions`).
//
// `ProviderRegistry` is the single source of truth for the configured set,
// owned by `BaseCoordinator` and persisted to UserDefaults. API keys are
// stored separately in `CredentialStore` (Keychain).

public enum ProviderType: String, Codable, Sendable, CaseIterable {
    case deepseek           // built-in; BYOK
    case relay              // built-in; zero-config (platform credit)
    case openaiCompatible = "openai-compatible"

    public var displayName: String {
        switch self {
        case .deepseek:         return "DeepSeek"
        case .relay:            return "Relay"
        case .openaiCompatible: return "OpenAI-Compatible"
        }
    }
}

public enum ProviderSource: String, Codable, Sendable {
    case builtin
    case user
}

public struct ProviderConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: String                  // stable across renames; keychain key
    public var name: String
    public var type: ProviderType
    public var baseUrl: String?
    public var models: [ProviderModel]     // catalog of models offered by this provider
    public var enabledModelIds: [String]   // subset visible in the picker
    public var source: ProviderSource

    public init(id: String, name: String, type: ProviderType, baseUrl: String? = nil,
                models: [ProviderModel] = [], enabledModelIds: [String] = [],
                source: ProviderSource = .user) {
        self.id = id
        self.name = name
        self.type = type
        self.baseUrl = baseUrl
        self.models = models
        self.enabledModelIds = enabledModelIds
        self.source = source
    }

    public var requiresApiKey: Bool {
        switch type {
        case .relay:                       return false
        case .deepseek, .openaiCompatible: return true
        }
    }
}

public struct ProviderModel: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - ProviderRegistry

public final class ProviderRegistry: ObservableObject, @unchecked Sendable {
    @Published public private(set) var providers: [ProviderConfig] = []

    private static let storageKey = "neox.providers.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.providers = Self.load(from: defaults)
        ensureBuiltins()
    }

    // MARK: persistence

    private static func load(from defaults: UserDefaults) -> [ProviderConfig] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([ProviderConfig].self, from: data)) ?? []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Make sure the built-in providers always exist, and clean up any
    /// stale built-ins that have since been removed (e.g. the legacy
    /// `deepseek` built-in is no longer offered out of the box — users
    /// who want DeepSeek can add it as a custom OpenAI-compatible provider).
    private func ensureBuiltins() {
        var changed = false

        // Drop legacy deepseek built-in if it was previously persisted as a
        // built-in. Preserve user-added custom DeepSeek configs (source=user).
        let legacyBuiltinIds: Set<String> = ["deepseek"]
        let before = providers.count
        providers.removeAll { p in
            legacyBuiltinIds.contains(p.id) && p.source == .builtin
        }
        if providers.count != before { changed = true }

        if !providers.contains(where: { $0.id == "relay" }) {
            providers.insert(Self.defaultRelay(), at: 0)
            changed = true
        }

        // Force-fix source field on built-ins in case older persisted state
        // still labels them as user-added.
        for i in providers.indices {
            if providers[i].id == "relay" {
                if providers[i].source != .builtin {
                    providers[i].source = .builtin
                    changed = true
                }
            }
        }
        if changed { persist() }
    }

    public static func defaultRelay() -> ProviderConfig {
        let models = [
            ProviderModel(id: "relay-deepseek-v4-flash", name: "DeepSeek V4 Flash (Relay)"),
            ProviderModel(id: "relay-deepseek-v4-pro",   name: "DeepSeek V4 Pro (Relay)"),
        ]
        return ProviderConfig(
            id: "relay",
            name: "Relay",
            type: .relay,
            baseUrl: "https://relay.ai.qili2.com/llm/v1",
            models: models,
            enabledModelIds: models.map(\.id),
            source: .builtin
        )
    }

    public static func defaultDeepseek() -> ProviderConfig {
        let models = [
            ProviderModel(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash"),
            ProviderModel(id: "deepseek-v4-pro",   name: "DeepSeek V4 Pro"),
        ]
        return ProviderConfig(
            id: "deepseek",
            name: "DeepSeek",
            type: .deepseek,
            baseUrl: "https://api.deepseek.com/v1",
            models: models,
            enabledModelIds: [],            // disabled by default until BYOK key is set
            source: .builtin
        )
    }

    // MARK: mutation

    public func upsert(_ config: ProviderConfig) {
        if let idx = providers.firstIndex(where: { $0.id == config.id }) {
            providers[idx] = config
        } else {
            providers.append(config)
        }
        persist()
    }

    public func delete(id: String) {
        guard let idx = providers.firstIndex(where: { $0.id == id }) else { return }
        if providers[idx].source == .builtin { return } // can't delete builtins
        providers.remove(at: idx)
        persist()
    }

    public func setModelEnabled(providerId: String, modelId: String, enabled: Bool) {
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else { return }
        var ids = providers[idx].enabledModelIds
        if enabled, !ids.contains(modelId) {
            ids.append(modelId)
        } else if !enabled {
            ids.removeAll { $0 == modelId }
        }
        providers[idx].enabledModelIds = ids
        persist()
    }

    public func setModels(providerId: String, models: [ProviderModel]) {
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else { return }
        providers[idx].models = models
        // Drop enabled ids that no longer exist
        let valid = Set(models.map(\.id))
        providers[idx].enabledModelIds = providers[idx].enabledModelIds.filter { valid.contains($0) }
        persist()
    }

    /// All enabled models across all providers, in stable provider order.
    public var enabledModelsByProvider: [(provider: ProviderConfig, models: [ProviderModel])] {
        providers.compactMap { p in
            let enabled = p.models.filter { p.enabledModelIds.contains($0.id) }
            return enabled.isEmpty ? nil : (p, enabled)
        }
    }
}

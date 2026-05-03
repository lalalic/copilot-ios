import Foundation

// MARK: - DTO

/// Wire shape of `GET https://relay.ai.qili2.com/apps/{appid}/models`
/// (see copilot-relay/lib/workspaces.js#getAppModels and lib/http-api.js).
private struct AppModelsEnvelope: Decodable {
    let ok: Bool
    let appid: String
    let models: [Entry]
    struct Entry: Decodable {
        let id: String
        let multiplier: Double?
        let `default`: Bool?
    }
}

// MARK: - Service (one-shot fetcher)

public enum RemoteModelCatalogError: Error, LocalizedError {
    case badURL
    case http(Int)
    case decode(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .badURL: return "Bad relay URL"
        case .http(let s): return "Relay returned HTTP \(s)"
        case .decode(let m): return "Decode failed: \(m)"
        case .empty: return "No models configured for this app"
        }
    }
}

public actor RemoteModelCatalogService {
    public static let shared = RemoteModelCatalogService()
    public init() {}

    /// Fetches the per-app supported model list from the relay and returns
    /// it merged with `ModelCatalog.allModels` so we keep nice display
    /// names / family / tier / description for known IDs. Unknown IDs get
    /// a synthesized `ModelInfo` (id used as name, family/tier=Other).
    /// Returns `(models, defaultId)`.
    public func fetch(appId: String,
                      relayBase: String = "https://relay.ai.qili2.com")
    async throws -> (models: [ModelInfo], defaultId: String?) {
        guard !appId.isEmpty,
              let url = URL(string: "\(relayBase)/apps/\(appId)/models") else {
            throw RemoteModelCatalogError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RemoteModelCatalogError.http(0) }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteModelCatalogError.http(http.statusCode)
        }
        let env: AppModelsEnvelope
        do {
            env = try JSONDecoder().decode(AppModelsEnvelope.self, from: data)
        } catch {
            throw RemoteModelCatalogError.decode(String(describing: error))
        }
        guard !env.models.isEmpty else { throw RemoteModelCatalogError.empty }

        let merged: [ModelInfo] = env.models.map { entry in
            if let known = ModelCatalog.model(for: entry.id) {
                // Trust server-side multiplier when present.
                return ModelInfo(
                    id: known.id, name: known.name, family: known.family,
                    tier: known.tier,
                    multiplier: entry.multiplier ?? known.multiplier,
                    description: known.description)
            }
            return ModelInfo(
                id: entry.id, name: entry.id, family: "Other",
                tier: .balanced, multiplier: entry.multiplier ?? 0,
                description: "")
        }
        let defId = env.models.first(where: { $0.default == true })?.id
        return (merged, defId)
    }
}

// MARK: - ObservableObject for SwiftUI

/// Drop-in store for views that want a per-app model list. Falls back to the
/// hardcoded `ModelCatalog.allModels` until the first successful load.
@MainActor
public final class RemoteModelCatalog: ObservableObject {
    @Published public private(set) var models: [ModelInfo] = ModelCatalog.allModels
    @Published public private(set) var defaultId: String? = nil
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var loadedAppId: String? = nil

    public init() {}

    public func load(appId: String,
                     relayBase: String = "https://relay.ai.qili2.com") async {
        isLoading = true
        lastError = nil
        do {
            let result = try await RemoteModelCatalogService.shared
                .fetch(appId: appId, relayBase: relayBase)
            self.models = result.models
            self.defaultId = result.defaultId
            self.loadedAppId = appId
        } catch {
            self.lastError = error.localizedDescription
            // Keep whatever models we already had.
        }
        isLoading = false
    }
}

import Foundation

/// Manages discovery and lookup of site adapters.
@MainActor
public final class AdapterRegistry {

    /// Key format: "site/name"
    private var adapters: [String: YAMLAdapter] = [:]

    public init() {}

    // MARK: - Registration

    /// Register an adapter from a YAML string.
    public func register(yaml: String) throws {
        let adapter = try YAMLAdapter.parse(yaml)
        let key = "\(adapter.site)/\(adapter.name)"
        adapters[key] = adapter
    }

    /// Register a pre-parsed adapter.
    public func register(adapter: YAMLAdapter) {
        let key = "\(adapter.site)/\(adapter.name)"
        adapters[key] = adapter
    }

    // MARK: - Lookup

    /// Find an adapter by site and action name.
    public func find(site: String, action: String) -> YAMLAdapter? {
        adapters["\(site)/\(action)"]
    }

    /// Number of registered adapters.
    public var adapterCount: Int {
        adapters.count
    }

    // MARK: - List

    /// List all registered adapters.
    public func listAll() -> [YAMLAdapter] {
        Array(adapters.values).sorted(by: { "\($0.site)/\($0.name)" < "\($1.site)/\($1.name)" })
    }

    /// List adapters for a specific site.
    public func listForSite(_ site: String) -> [YAMLAdapter] {
        adapters.values.filter { $0.site == site }
            .sorted(by: { $0.name < $1.name })
    }

    /// Formatted listing of all adapters for display.
    public func listFormatted() -> String {
        if adapters.isEmpty {
            return "No site adapters registered."
        }

        let grouped = Dictionary(grouping: adapters.values, by: { $0.site })
        var lines: [String] = ["Available site adapters:"]

        for site in grouped.keys.sorted() {
            lines.append("\n  \(site):")
            for adapter in grouped[site]!.sorted(by: { $0.name < $1.name }) {
                let auth = adapter.auth == .none ? "" : " [auth required]"
                let browser = adapter.requiresBrowser ? " [browser]" : ""
                lines.append("    - \(adapter.name): \(adapter.adapterDescription)\(auth)\(browser)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Load from Directory

    /// Load all `.yaml` adapter files from a directory.
    public func loadFromDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil)
        for fileURL in contents where fileURL.pathExtension == "yaml" {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            try register(yaml: text)
        }
    }

    /// Load bundled adapters from the module's bundle.
    public func loadBundledAdapters() {
        // Load from Bundle.module if adapters are included as resources
        // For now, register the built-in HackerNews adapter
        let hnTop = """
        site: hackernews
        name: top
        description: Get top Hacker News stories
        auth: none
        requiresBrowser: false
        args:
          limit:
            type: int
            default: 20
            description: Number of stories to return
        pipeline:
          - fetch: https://hacker-news.firebaseio.com/v0/topstories.json
          - slice: { to: 30 }
          - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.by }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        let hnNew = """
        site: hackernews
        name: new
        description: Get newest Hacker News stories
        auth: none
        requiresBrowser: false
        args:
          limit:
            type: int
            default: 20
            description: Number of stories to return
        pipeline:
          - fetch: https://hacker-news.firebaseio.com/v0/newstories.json
          - slice: { to: 30 }
          - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.by }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        let hnBest = """
        site: hackernews
        name: best
        description: Get best Hacker News stories
        auth: none
        requiresBrowser: false
        args:
          limit:
            type: int
            default: 20
            description: Number of stories to return
        pipeline:
          - fetch: https://hacker-news.firebaseio.com/v0/beststories.json
          - slice: { to: 30 }
          - fetchEach: "https://hacker-news.firebaseio.com/v0/item/${{ item }}.json"
          - filter: "item.title != nil"
          - map: { rank: "${{ index + 1 }}", title: "${{ item.title }}", score: "${{ item.score }}", author: "${{ item.by }}", url: "${{ item.url }}" }
          - slice: { to: 20 }
        """

        for yaml in [hnTop, hnNew, hnBest] {
            try? register(yaml: yaml)
        }
    }
}

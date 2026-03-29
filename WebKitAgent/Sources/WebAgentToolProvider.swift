import Foundation
import CopilotSDK

/// Provides a single CopilotSDK tool (`web_agent`) with sub-commands for browser automation.
/// The skill system prompt should describe available sub-commands.
@MainActor
public final class WebAgentToolProvider {

    public let manager: WebViewManager
    public let registry: AdapterRegistry
    private let pipelineEngine: PipelineEngine

    public init(manager: WebViewManager) {
        self.manager = manager
        self.registry = AdapterRegistry()
        self.pipelineEngine = PipelineEngine()
        registry.loadBundledAdapters()
    }

    // MARK: - Skill prompt describing sub-commands

    /// System prompt snippet describing all web_agent sub-commands.
    /// Append this to the agent's system prompt so the LLM knows how to use the tool.
    public static let skillPrompt = """
    You have a `web_agent` tool for browser automation. Use the `command` parameter to specify the action.

    Sub-commands:
    - `navigate` — Go to a URL. Params: `url` (required). Waits for page load.
    - `snapshot` — Scan page for interactive elements. Returns refs like r0, r1, r2... Always snapshot after navigating or clicking to get fresh refs.
    - `click` — Click an element. Params: `ref` (required, e.g. "r5").
    - `type` — Type into an input/textarea. Params: `ref` (required), `text` (required), `clear` (optional, default true).
    - `download` — Download a file. Params: `ref` (element with href) OR `url` (direct URL), `filename` (optional override).
    - `upload` — Upload file to <input type="file">. Params: `ref` (required), `filePath` (required).
    - `site` — Run a site-specific adapter. Params: `site` (site name), `action` (adapter name). Use action="list" to see available adapters.
    - `evaluate` — Run JavaScript on the current page. Params: `script` (required). Returns the result.
    - `screenshot` — Take a screenshot of the current page. Returns base64 JPEG.

    Workflow: navigate → snapshot → read refs → click/type/download as needed → snapshot again after page changes.
    For known sites, prefer `site` command over manual navigation — it's faster and deterministic.
    """

    // MARK: - Single Tool

    public var tools: [ToolDefinition] {
        [webAgentTool]
    }

    private var webAgentTool: ToolDefinition {
        ToolDefinition(
            name: "web_agent",
            description: "Browser automation tool. Use 'command' to specify action: navigate, snapshot, click, type, download, upload. See skill prompt for details.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("navigate"), .string("snapshot"), .string("click"),
                            .string("type"), .string("download"), .string("upload"),
                            .string("site"), .string("evaluate"), .string("screenshot")
                        ]),
                        "description": .string("The sub-command to execute")
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("URL for navigate or download")
                    ]),
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref from snapshot, e.g. 'r5'")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to type (for type command)")
                    ]),
                    "clear": .object([
                        "type": .string("boolean"),
                        "description": .string("Clear existing text before typing. Default true.")
                    ]),
                    "filename": .object([
                        "type": .string("string"),
                        "description": .string("Override filename for download")
                    ]),
                    "filePath": .object([
                        "type": .string("string"),
                        "description": .string("File path for upload")
                    ]),
                    "site": .object([
                        "type": .string("string"),
                        "description": .string("Site name for site command (e.g. hackernews)")
                    ]),
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("Action name for site command (e.g. top, list)")
                    ]),
                    "script": .object([
                        "type": .string("string"),
                        "description": .string("JavaScript code to evaluate (for evaluate command)")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: WebAgent not available" }
            guard case .object(let dict) = args,
                  case .string(let command) = dict["command"] else {
                return "Error: 'command' parameter required"
            }
            return try await self.dispatch(command: command, args: dict)
        }
    }

    // MARK: - Dispatch

    private func dispatch(command: String, args: [String: JSONValue]) async throws -> String {
        switch command {
        case "navigate":
            guard case .string(let url) = args["url"] else {
                return "Error: 'url' required for navigate"
            }
            return try await manager.navigate(to: url)

        case "snapshot":
            return try await manager.snapshot()

        case "click":
            guard case .string(let ref) = args["ref"] else {
                return "Error: 'ref' required for click"
            }
            return try await manager.click(ref: ref)

        case "type":
            guard case .string(let ref) = args["ref"],
                  case .string(let text) = args["text"] else {
                return "Error: 'ref' and 'text' required for type"
            }
            var clear = true
            if case .bool(let c) = args["clear"] { clear = c }
            return try await manager.type(ref: ref, text: text, clear: clear)

        case "download":
            var ref: String?
            var url: String?
            var filename: String?
            if case .string(let r) = args["ref"] { ref = r }
            if case .string(let u) = args["url"] { url = u }
            if case .string(let f) = args["filename"] { filename = f }
            if ref == nil && url == nil {
                return "Error: 'ref' or 'url' required for download"
            }
            return try await manager.download(ref: ref, url: url, filename: filename)

        case "upload":
            guard case .string(let ref) = args["ref"],
                  case .string(let filePath) = args["filePath"] else {
                return "Error: 'ref' and 'filePath' required for upload"
            }
            return try await manager.upload(ref: ref, filePath: filePath)

        case "site":
            return try await dispatchSite(args: args)

        case "evaluate":
            guard case .string(let script) = args["script"] else {
                return "Error: 'script' parameter required for evaluate"
            }
            return try await manager.evaluateJSPublic(script)

        case "screenshot":
            if let base64 = await manager.screenshot() {
                return "data:image/jpeg;base64,\(base64)"
            }
            return "Error: screenshot failed"

        default:
            return "Error: unknown command '\(command)'. Use: navigate, snapshot, click, type, download, upload, site"
        }
    }

    // MARK: - Site Adapter Dispatch

    private func dispatchSite(args: [String: JSONValue]) async throws -> String {
        // action=list → list all adapters
        if case .string(let action) = args["action"], action == "list" {
            return registry.listFormatted()
        }

        guard case .string(let site) = args["site"] else {
            return "Error: 'site' parameter required for site command. Use action=\"list\" to see available adapters."
        }

        guard case .string(let action) = args["action"] else {
            // List adapters for this site
            let siteAdapters = registry.listForSite(site)
            if siteAdapters.isEmpty {
                return "Error: no adapters found for site '\(site)'. Use action=\"list\" to see all adapters."
            }
            let names = siteAdapters.map { "  - \($0.name): \($0.adapterDescription)" }.joined(separator: "\n")
            return "Available actions for \(site):\n\(names)"
        }

        guard let adapter = registry.find(site: site, action: action) else {
            return "Error: adapter '\(site)/\(action)' not found. Use action=\"list\" to see available adapters."
        }

        // Collect args from the tool call
        var adapterArgs: [String: String] = [:]
        for arg in adapter.args {
            if case .string(let val) = args[arg.name] {
                adapterArgs[arg.name] = val
            } else if case .int(let val) = args[arg.name] {
                adapterArgs[arg.name] = String(val)
            } else if let defaultVal = arg.defaultValue {
                adapterArgs[arg.name] = defaultVal
            }
        }

        // Execute based on adapter type
        if adapter.requiresBrowser {
            return try await executeBrowserAdapter(adapter, args: adapterArgs)
        } else {
            return try await executePipelineAdapter(adapter, args: adapterArgs)
        }
    }

    private func executePipelineAdapter(_ adapter: YAMLAdapter, args: [String: String]) async throws -> String {
        let results = try await pipelineEngine.execute(pipeline: adapter.pipeline, args: args)

        // Apply limit from args if specified
        var limited = results
        if let limitStr = args["limit"], let limit = Int(limitStr), limit < results.count {
            limited = Array(results.prefix(limit))
        }

        return PipelineEngine.formatOutput(limited)
    }

    private func executeBrowserAdapter(_ adapter: YAMLAdapter, args: [String: String]) async throws -> String {
        // Navigate to pre-navigate URL if specified
        if let url = adapter.preNavigate {
            _ = try await manager.navigate(to: url)
        }

        // Wait if specified
        if let wait = adapter.waitSeconds, wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }

        // Execute script if present
        if let script = adapter.script {
            let resultJSON = try await manager.evaluateJSPublic(script)
            // Try to parse as JSON array for formatting
            if let data = resultJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return PipelineEngine.formatOutput(json)
            }
            return resultJSON
        }

        return "Error: browser adapter '\(adapter.site)/\(adapter.name)' has no script defined."
    }
}

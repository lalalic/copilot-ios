import Foundation
import CopilotSDK

/// Provides a single CopilotSDK tool (`web_agent`) with sub-commands for browser automation.
/// The skill system prompt should describe available sub-commands.
@MainActor
public final class WebAgentToolProvider {

    public let manager: WebViewManager

    public init(manager: WebViewManager) {
        self.manager = manager
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

    Workflow: navigate → snapshot → read refs → click/type/download as needed → snapshot again after page changes.
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
                            .string("type"), .string("download"), .string("upload")
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

        default:
            return "Error: unknown command '\(command)'. Use: navigate, snapshot, click, type, download, upload"
        }
    }
}

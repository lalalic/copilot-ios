#if os(iOS)
import Foundation

/// Provides a single MCP tool (`app_agent`) with sub-commands for native iOS UI automation.
/// Uses accessibility APIs to scan, tap, and type in the app's own UI.
@MainActor
public final class AppAgentToolProvider {

    public let scanner: AccessibilityScanner
    public let engine: InteractionEngine

    public init() {
        self.scanner = AccessibilityScanner()
        self.engine = InteractionEngine(scanner: scanner)
    }

    public init(scanner: AccessibilityScanner, engine: InteractionEngine) {
        self.scanner = scanner
        self.engine = engine
    }

    // MARK: - Skill Prompt

    /// System prompt snippet describing app_agent sub-commands.
    public static let skillPrompt = """
    You have an `app_agent` tool for native iOS app UI automation. Use the `command` parameter to specify the action.

    Sub-commands:
    - `snapshot` — Scan the screen for interactive elements. Returns tree with refs r0, r1, r2...
    - `tap` — Tap an element. Params: `ref` (required).
    - `type` — Type into a text field. Params: `ref` (required), `text` (required), `clear` (optional, default true).
    - `swipe` — Swipe on screen or element. Params: `direction` (up/down/left/right), `ref` (optional).
    - `long_press` — Long-press an element. Params: `ref` (required), `duration` (optional, seconds).
    - `find` — Find elements by text content. Params: `text` (required). Searches labels and values.
    - `scroll_to` — Scroll to make an element visible. Params: `ref` (required).
    - `pick` — Select a value in a picker, date picker, or segmented control. Params: `ref` (required), `value` (required), `component` (optional, picker column index, default 0).
    - `screenshot` — Take a screenshot. Returns base64 JPEG.

    Workflow: snapshot → read refs → tap/type/swipe → snapshot again after interactions.
    """

    // MARK: - Single Tool

    public var tools: [ToolDefinition] {
        [appAgentTool]
    }

    private var appAgentTool: ToolDefinition {
        ToolDefinition(
            name: "app_agent",
            description: "Native iOS app UI automation. Use this tool to test and manipulate the app. Use 'command' to specify action: snapshot (get UI elements), tap (tap element by ref), tap_xy, type (enter text), swipe, long_press, find, scroll_to, pick, screenshot.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("snapshot"), .string("tap"),
                            .string("tap_xy"), .string("type"),
                            .string("screenshot"),
                            .string("swipe"), .string("long_press"),
                            .string("find"), .string("scroll_to"),
                            .string("pick")
                        ]),
                        "description": .string("The sub-command to execute")
                    ]),
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref from snapshot, e.g. 'r5'")
                    ]),
                    "x": .object([
                        "type": .string("number"),
                        "description": .string("X coordinate for tap_xy command")
                    ]),
                    "y": .object([
                        "type": .string("number"),
                        "description": .string("Y coordinate for tap_xy command")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to type (type command), search for (find command), or value to select (pick command)")
                    ]),
                    "clear": .object([
                        "type": .string("boolean"),
                        "description": .string("Clear existing text before typing. Default true.")
                    ]),
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")]),
                        "description": .string("Swipe direction (for swipe command)")
                    ]),
                    "duration": .object([
                        "type": .string("number"),
                        "description": .string("Long-press duration in seconds. Default 1.0.")
                    ]),
                    "component": .object([
                        "type": .string("integer"),
                        "description": .string("Picker component (column) index for pick command. Default 0.")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            handler: { [weak self] (args: JSONValue) async throws -> String in
                guard let self else { return "Error: AppAgent not available" }
                guard case .object(let dict) = args,
                      case .string(let command) = dict["command"] else {
                    return "Error: 'command' parameter required"
                }
                return await MainActor.run {
                    self.dispatch(command: command, args: dict)
                }
            }
        )
    }

    // MARK: - Dispatch

    private func dispatch(command: String, args: [String: JSONValue]) -> String {
        switch command {
        case "snapshot":
            return scanner.scan()

        case "tap":
            guard case .string(let ref) = args["ref"] else {
                return "Error: 'ref' required for tap"
            }
            return engine.tap(ref: ref)

        case "tap_xy":
            var x: Double?
            var y: Double?
            if case .double(let v) = args["x"] { x = v }
            if case .int(let v) = args["x"] { x = Double(v) }
            if case .double(let v) = args["y"] { y = v }
            if case .int(let v) = args["y"] { y = Double(v) }
            guard let x, let y else {
                return "Error: 'x' and 'y' required for tap_xy. Get coordinates from snapshot output."
            }
            return engine.tapXY(x: x, y: y)

        case "type":
            guard case .string(let ref) = args["ref"],
                  case .string(let text) = args["text"] else {
                return "Error: 'ref' and 'text' required for type"
            }
            var clear = true
            if case .bool(let c) = args["clear"] { clear = c }
            return engine.type(ref: ref, text: text, clear: clear)

        case "swipe":
            guard case .string(let direction) = args["direction"] else {
                return "Error: 'direction' required for swipe (up/down/left/right)"
            }
            var ref: String?
            if case .string(let r) = args["ref"] { ref = r }
            return engine.swipe(direction: direction, ref: ref)

        case "long_press":
            guard case .string(let ref) = args["ref"] else {
                return "Error: 'ref' required for long_press"
            }
            var duration: TimeInterval = 1.0
            if case .double(let d) = args["duration"] { duration = d }
            if case .int(let i) = args["duration"] { duration = Double(i) }
            return engine.longPress(ref: ref, duration: duration)

        case "find":
            guard case .string(let text) = args["text"] else {
                return "Error: 'text' required for find"
            }
            return engine.find(text: text)

        case "scroll_to":
            guard case .string(let ref) = args["ref"] else {
                return "Error: 'ref' required for scroll_to"
            }
            return engine.scrollTo(ref: ref)

        case "pick":
            guard case .string(let ref) = args["ref"],
                  case .string(let value) = args["value"] else {
                return "Error: 'ref' and 'value' required for pick"
            }
            var component = 0
            if case .int(let c) = args["component"] { component = c }
            return engine.pick(ref: ref, value: value, component: component)

        case "screenshot":
            var quality: CGFloat = 0.1
            if case .int(let q) = args["quality"] { quality = CGFloat(q) / 100.0 }
            if case .double(let q) = args["quality"] { quality = q / 100.0 }
            if let base64 = engine.screenshot(quality: quality) {
                return base64
            }
            return "Error: screenshot failed"

        default:
            return "Error: unknown command '\(command)'. Use: snapshot, tap, type, swipe, long_press, find, scroll_to, pick, screenshot"
        }
    }
}
#endif

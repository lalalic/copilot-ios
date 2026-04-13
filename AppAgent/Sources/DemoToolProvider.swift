#if os(iOS)
import Foundation

/// Provides a single MCP tool (`demo`) with sub-commands for visual demo overlays.
/// Mirrors the `app_agent` sub-command pattern.
@MainActor
public final class DemoToolProvider {

    public let runtime: DemoRuntime

    public init(runtime: DemoRuntime) {
        self.runtime = runtime
    }

    // MARK: - Skill Prompt

    public static let skillPrompt = """
    You have a `demo` tool for visual demo overlays on iOS. Use the `command` parameter to specify the action.

    Sub-commands:
    - `step` — Show step badge. Params: `title` (required).
    - `spotlight` — Dim background and spotlight an element. Params: `ref` or `label` (one required), `text` (optional tooltip).
    - `annotate` — Show tooltip near element. Params: `ref` or `label` (one required), `text` (required).
    - `caption` — Show bottom caption bar. Params: `text` (required).
    - `say` — TTS narration + caption bar. Params: `text` (required). Async, waits for speech to finish.
    - `cursor` — Animate cursor to element. Params: `ref` or `label` (one required).
    - `highlight` — Brief pulse on element. Params: `ref` or `label` (one required).
    - `clear` — Remove all overlays.
    - `pause` — Freeze overlays and timeline.
    - `resume` — Unfreeze overlays and timeline.
    - `wait` — Wait for duration. Params: `ms` (required).
    - `start_recording` — Start event timeline recording.
    - `stop_recording` — Stop recording, return events JSON.

    Typical workflow: step → spotlight/say → app_agent tap → demo clear → next step.
    """

    // MARK: - Tool Definition

    public var tools: [ToolDefinition] {
        [demoTool]
    }

    private var demoTool: ToolDefinition {
        ToolDefinition(
            name: "demo",
            description: "Visual demo overlay for iOS app. Show spotlights, captions, TTS narration, step badges, cursor animations. Use 'command' to specify action.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("step"), .string("spotlight"),
                            .string("annotate"), .string("caption"),
                            .string("say"), .string("cursor"),
                            .string("highlight"), .string("clear"),
                            .string("pause"), .string("resume"),
                            .string("wait"),
                            .string("start_recording"), .string("stop_recording")
                        ]),
                        "description": .string("The sub-command to execute")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Step title (for step command)")
                    ]),
                    "ref": .object([
                        "type": .string("string"),
                        "description": .string("Element ref from snapshot, e.g. 'r5' (for spotlight, annotate, cursor, highlight)")
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Element label text to match (alt to ref)")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text content: tooltip text (spotlight/annotate), caption text, or speech text (say)")
                    ]),
                    "ms": .object([
                        "type": .string("integer"),
                        "description": .string("Wait duration in milliseconds (for wait command)")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            handler: { [weak self] (args: JSONValue) async throws -> String in
                guard let self else { return "Error: DemoKit not available" }
                guard case .object(let dict) = args,
                      case .string(let command) = dict["command"] else {
                    return "Error: 'command' parameter required"
                }
                return await self.dispatch(command: command, args: dict)
            }
        )
    }

    // MARK: - Dispatch

    @MainActor
    func dispatch(command: String, args: [String: JSONValue]) async -> String {
        let ref = args["ref"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
        let label = args["label"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
        let text = args["text"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        switch command {
        case "step":
            guard let title = args["title"].flatMap({ if case .string(let s) = $0 { return s } else { return nil } }) else {
                return "Error: 'title' required for step"
            }
            runtime.step(title)
            return "Step \(runtime.stepNumber): \(title)"

        case "spotlight":
            guard ref != nil || label != nil else {
                return "Error: 'ref' or 'label' required for spotlight"
            }
            runtime.spotlight(ref: ref, label: label, text: text)
            return "Spotlight on \(ref ?? label ?? "?")" + (text.map { " — \($0)" } ?? "")

        case "annotate":
            guard ref != nil || label != nil, let text else {
                return "Error: 'ref' or 'label' + 'text' required for annotate"
            }
            runtime.annotate(ref: ref, label: label, text: text)
            return "Annotated \(ref ?? label ?? "?"): \(text)"

        case "caption":
            guard let text else {
                return "Error: 'text' required for caption"
            }
            runtime.caption(text)
            return "Caption: \(text)"

        case "say":
            guard let text else {
                return "Error: 'text' required for say"
            }
            await runtime.say(text)
            return "Said: \(text)"

        case "cursor":
            guard ref != nil || label != nil else {
                return "Error: 'ref' or 'label' required for cursor"
            }
            await runtime.cursorTo(ref: ref, label: label)
            return "Cursor moved to \(ref ?? label ?? "?")"

        case "highlight":
            guard ref != nil || label != nil else {
                return "Error: 'ref' or 'label' required for highlight"
            }
            runtime.highlight(ref: ref, label: label)
            return "Highlighted \(ref ?? label ?? "?")"

        case "clear":
            runtime.clear()
            return "Cleared all overlays"

        case "pause":
            runtime.pause()
            return "Paused"

        case "resume":
            runtime.resume()
            return "Resumed"

        case "wait":
            var ms: Int = 1000
            if case .int(let m) = args["ms"] { ms = m }
            if case .double(let m) = args["ms"] { ms = Int(m) }
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "Waited \(ms)ms"

        case "start_recording":
            runtime.startRecording()
            return "Recording started"

        case "stop_recording":
            let events = runtime.stopRecording()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(events), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "[]"

        default:
            return "Error: unknown command '\(command)'. Use: step, spotlight, annotate, caption, say, cursor, highlight, clear, pause, resume, wait, start_recording, stop_recording"
        }
    }
}
#endif

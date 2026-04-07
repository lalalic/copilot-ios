import Foundation
import JavaScriptCore
import os.log

private let logger = Logger(subsystem: "com.copilot-ios.sdk", category: "Script")

/// Provides a `run_script` tool that executes JavaScript in a sandboxed JSContext.
///
/// Pre-bound helpers available in scripts:
/// - `readFile(path)` → string
/// - `writeFile(path, content)` → boolean
/// - `listFiles(path)` → string[]
/// - `runCommand(cmd)` → string (output)
/// - `console.log/warn/error(...)` → captured output
public final class ScriptToolProvider: @unchecked Sendable {

    private let workspaceURL: URL
    private let terminalProvider: TerminalToolProvider

    public init(workspaceURL: URL, terminalProvider: TerminalToolProvider) {
        self.workspaceURL = workspaceURL
        self.terminalProvider = terminalProvider
    }

    public var tools: [ToolDefinition] {
        [runScriptTool]
    }

    // MARK: - Script execution

    private func executeScript(_ code: String) -> String {
        guard let ctx = JSContext() else {
            return "Error: failed to create JSContext"
        }

        let output = OutputCollector()
        let workspace = workspaceURL
        let terminal = terminalProvider

        // Exception handler
        ctx.exceptionHandler = { _, error in
            output.append("Error: \(error?.toString() ?? "unknown JS error")")
        }

        // console.log / warn / error / info
        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments()?
                .compactMap { ($0 as? JSValue)?.toString() } ?? []
            output.append(args.joined(separator: " "))
        }
        ctx.setObject(log, forKeyedSubscript: "__log" as NSString)
        ctx.evaluateScript("""
            var console = { log: __log, error: __log, warn: __log, info: __log };
            """)

        // readFile(path) -> string
        let readFile: @convention(block) (String) -> String = { path in
            let resolved = Self.resolvePath(path, base: workspace)
            guard Self.isInsideSandbox(resolved, base: workspace) else {
                return "Error: path outside workspace"
            }
            return (try? String(contentsOf: resolved, encoding: .utf8))
                ?? "Error: cannot read file"
        }
        ctx.setObject(readFile, forKeyedSubscript: "readFile" as NSString)

        // writeFile(path, content) -> bool
        let writeFile: @convention(block) (String, String) -> Bool = { path, content in
            let resolved = Self.resolvePath(path, base: workspace)
            guard Self.isInsideSandbox(resolved, base: workspace) else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: resolved.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(to: resolved, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        ctx.setObject(writeFile, forKeyedSubscript: "writeFile" as NSString)

        // listFiles(path) -> [string]
        let listFiles: @convention(block) (String) -> [String] = { path in
            let resolved = Self.resolvePath(path, base: workspace)
            guard Self.isInsideSandbox(resolved, base: workspace) else { return [] }
            return (try? FileManager.default.contentsOfDirectory(atPath: resolved.path)) ?? []
        }
        ctx.setObject(listFiles, forKeyedSubscript: "listFiles" as NSString)

        // runCommand(cmd) -> string
        let runCommand: @convention(block) (String) -> String = { cmd in
            let result = terminal.execute(cmd)
            if result.exitCode != 0 {
                return "Exit code: \(result.exitCode)\n\(result.output)"
            }
            return result.output
        }
        ctx.setObject(runCommand, forKeyedSubscript: "runCommand" as NSString)

        // Execute the script
        let result = ctx.evaluateScript(code)

        // Build response: console output + return value
        let logged = output.lines
        let returnValue = result?.isUndefined == false ? result?.toString() : nil

        var parts: [String] = []
        if !logged.isEmpty {
            parts.append(logged.joined(separator: "\n"))
        }
        if let rv = returnValue, rv != "undefined" {
            parts.append("→ \(rv)")
        }

        let response = parts.isEmpty ? "(no output)" : parts.joined(separator: "\n")
        logger.info("run_script: \(code.prefix(80)) → \(response.count) chars")
        return response
    }

    // MARK: - Path helpers

    private static func resolvePath(_ path: String, base: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return base.appendingPathComponent(path)
    }

    private static func isInsideSandbox(_ url: URL, base: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path)
    }

    // MARK: - Tool definition

    private var runScriptTool: ToolDefinition {
        ToolDefinition(
            name: "run_script",
            description: """
                Execute JavaScript code on the device using JavaScriptCore. \
                Available helpers: readFile(path), writeFile(path, content), \
                listFiles(path), runCommand(cmd), console.log(). \
                Paths are relative to the workspace. Use for loops, JSON processing, \
                data transformations, and multi-step operations.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("JavaScript code to execute")
                    ])
                ]),
                "required": .array([.string("code")])
            ]),
            overridesBuiltInTool: false,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: ScriptToolProvider unavailable" }
            guard case .object(let dict) = args,
                  case .string(let code) = dict["code"] else {
                return "Error: 'code' (string) required"
            }
            return self.executeScript(code)
        }
    }
}

/// Thread-safe output collector for console.log capture.
private final class OutputCollector: @unchecked Sendable {
    private var _lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        _lines.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }
}

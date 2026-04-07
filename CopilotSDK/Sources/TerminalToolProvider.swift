import Foundation
import os.log

#if canImport(ios_system)
import ios_system
#endif

private let logger = Logger(subsystem: "com.copilot-ios.sdk", category: "Terminal")

/// Provides a `run_in_terminal` tool backed by ios_system.
/// Executes Unix commands (ls, cat, grep, curl, etc.) sandboxed to the workspace.
public final class TerminalToolProvider: @unchecked Sendable {

    private let workspaceURL: URL
    private let queue = DispatchQueue(label: "com.copilot.terminal", qos: .userInitiated)
    private var initialized = false

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    public var tools: [ToolDefinition] {
        #if canImport(ios_system)
        return [runInTerminalTool]
        #else
        return []
        #endif
    }

    /// Public API for executing a command and getting the result.
    /// Used by ScriptToolProvider's `runCommand()` JS bridge.
    public func execute(_ command: String) -> (output: String, exitCode: Int32) {
        #if canImport(ios_system)
        return queue.sync { executeCommand(command) }
        #else
        return ("Error: ios_system not available on this platform", -1)
        #endif
    }

    #if canImport(ios_system)

    private func initializeIfNeeded() {
        guard !initialized else { return }
        initializeEnvironment()
        ios_setMiniRoot(workspaceURL.path)
        initialized = true
    }

    private func executeCommand(_ command: String) -> (output: String, exitCode: Int32) {
        initializeIfNeeded()
        
        // Set process CWD and env so both getcwd()-based and $PWD-based commands work
        let wsPath = workspaceURL.path
        let chdirResult = chdir(wsPath)
        setenv("PWD", wsPath, 1)
        setenv("HOME", wsPath, 1)
        logger.info("chdir(\(wsPath)) = \(chdirResult), getcwd = \(String(cString: getcwd(nil, 0) ?? strdup("nil")))")

        // Create pipe for capturing stdout
        var pipeFds = [Int32](repeating: 0, count: 2)
        guard pipe(&pipeFds) == 0 else {
            return ("Error: pipe() failed", -1)
        }
        let readFd = pipeFds[0]
        let writeFd = pipeFds[1]

        // Save original stdout fd and redirect to pipe
        let savedOut = dup(STDOUT_FILENO)
        dup2(writeFd, STDOUT_FILENO)
        close(writeFd)

        // Also set thread-local streams so ios_system picks up the redirect
        let pipeOut = fdopen(STDOUT_FILENO, "w")
        ios_setStreams(stdin, pipeOut, stderr)

        // Execute
        let exitCode = Int32(ios_system(command))

        // Flush and restore stdout
        fflush(pipeOut)
        dup2(savedOut, STDOUT_FILENO)
        close(savedOut)
        ios_setStreams(stdin, stdout, stderr)

        // Read captured output (non-blocking since write end is closed)
        let flags = fcntl(readFd, F_GETFL)
        fcntl(readFd, F_SETFL, flags | O_NONBLOCK)

        var outputData = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let bytesRead = read(readFd, buf, bufSize)
            if bytesRead > 0 {
                outputData.append(buf, count: bytesRead)
            } else {
                break
            }
        }
        close(readFd)

        let output = String(data: outputData, encoding: .utf8) ?? ""
        logger.info("run_in_terminal: \(command.prefix(80)) → exit \(exitCode) (\(output.count) chars)")
        return (output, exitCode)
    }

    private var runInTerminalTool: ToolDefinition {
        ToolDefinition(
            name: "run_in_terminal",
            description: """
                Execute a shell command on the device. Supports standard Unix commands: \
                ls, cat, grep, find, mkdir, cp, mv, rm, sed, awk, curl, tar, echo, wc, \
                sort, head, tail, touch, chmod, pwd, date, env, du, df. \
                Commands run sandboxed in the workspace directory. \
                Use && to chain commands. Use | for pipes.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to execute, e.g. 'ls -la' or 'grep -r TODO .'")
                    ]),
                    "explanation": .object([
                        "type": .string("string"),
                        "description": .string("Brief description of what the command does (optional)")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            overridesBuiltInTool: true,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: TerminalToolProvider unavailable" }
            guard case .object(let dict) = args,
                  case .string(let command) = dict["command"] else {
                return "Error: 'command' (string) required"
            }

            let result = self.queue.sync {
                self.executeCommand(command)
            }

            var output = result.output
            let maxLen = 60_000
            if output.count > maxLen {
                output = String(output.prefix(maxLen)) + "\n\n[Output truncated at 60KB]"
            }

            if result.exitCode != 0 {
                return "Exit code: \(result.exitCode)\n\(output)"
            }
            return output.isEmpty ? "(no output)" : output
        }
    }

    #endif
}

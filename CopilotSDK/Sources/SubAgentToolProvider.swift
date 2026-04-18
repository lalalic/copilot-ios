import Foundation
import os.log

private let logger = Logger(subsystem: "com.copilot-ios.sdk", category: "SubAgent")

/// Parsed frontmatter from an agent.md file.
private struct AgentFrontmatter {
    var name: String?
    var description: String?
    var model: String?
    var tools: [String]?
    var skills: [String]?
}

/// Provides the `task` tool that spawns a separate relay session
/// using a named agent's instructions, runs a task, and returns the result.
public final class SubAgentToolProvider: @unchecked Sendable {
    private let workspaceURL: URL
    private let relayHost: String
    private let relayPort: UInt16
    private let userId: String?
    public var appId: String?
    private let toolsBuilder: @Sendable () -> [ToolDefinition]
    /// Callback for progress reports from sub-agents.
    public var onProgress: (@Sendable (_ agent: String, _ progress: String) -> Void)?

    /// - Parameters:
    ///   - workspaceURL: Root workspace directory (contains .github/agents/)
    ///   - relayHost: Relay server hostname
    ///   - relayPort: Relay server port
    ///   - userId: User ID for session routing
    ///   - toolsBuilder: Closure that builds shared tools (memory, file, etc.) for the sub-agent.
    ///                   Should NOT include task tool itself to prevent recursion.
    public init(
        workspaceURL: URL,
        relayHost: String,
        relayPort: UInt16,
        userId: String?,
        toolsBuilder: @escaping @Sendable () -> [ToolDefinition]
    ) {
        self.workspaceURL = workspaceURL
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.userId = userId
        self.toolsBuilder = toolsBuilder
    }

    public var tools: [ToolDefinition] {
        [runSubAgentTool]
    }

    private var agentsDirectory: URL {
        workspaceURL
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// List available agent names by scanning .github/agents/*.agent.md
    private func availableAgents() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: agentsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.hasSuffix(".agent.md") }
            .map { $0.lastPathComponent.replacingOccurrences(of: ".agent.md", with: "") }
            .sorted()
    }

    /// Parse YAML frontmatter from agent.md content.
    /// Supports: name, description, model, tools (list), skills (list)
    private func parseFrontmatter(_ content: String) -> (frontmatter: AgentFrontmatter, body: String) {
        var fm = AgentFrontmatter()
        var body = content

        guard content.hasPrefix("---") else { return (fm, body) }
        let lines = content.components(separatedBy: "\n")
        guard let endIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (fm, body)
        }

        let fmLines = Array(lines[1..<endIndex])
        body = lines[(endIndex + 1)...].joined(separator: "\n")

        var currentKey: String?
        var currentList: [String] = []

        func flushList() {
            guard let key = currentKey, !currentList.isEmpty else { return }
            switch key {
            case "tools": fm.tools = currentList
            case "skills": fm.skills = currentList
            default: break
            }
            currentList = []
            currentKey = nil
        }

        for line in fmLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                // List item
                let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                currentList.append(value)
                continue
            }

            flushList()

            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            if value.isEmpty {
                // Next lines will be list items
                currentKey = key
            } else {
                switch key {
                case "name": fm.name = value
                case "description": fm.description = value
                case "model": fm.model = value
                default: break
                }
            }
        }
        flushList()

        return (fm, body)
    }

    /// Read and parse agent file from .github/agents/{name}.agent.md
    private func loadAgent(_ name: String) -> (frontmatter: AgentFrontmatter, body: String)? {
        let file = agentsDirectory.appendingPathComponent("\(name).agent.md")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parseFrontmatter(content)
    }

    private var runSubAgentTool: ToolDefinition {
        ToolDefinition(
            name: "task",
            description: "Run a named sub-agent in a separate session. The sub-agent gets its own conversation context and can use shared tools (memory, files). Available agents: \(availableAgents().joined(separator: ", "))",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "agent": .object([
                        "type": .string("string"),
                        "description": .string("Agent name (matches .github/agents/{name}.agent.md)"),
                    ]),
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("The task/prompt to send to the sub-agent"),
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Model override (default: from agent frontmatter or gpt-4.1-mini)"),
                    ]),
                    "async": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, run in background and return immediately with a task ID. Result is written to .neo/reports/subagents/{taskId}.md"),
                    ]),
                ]),
                "required": .array([.string("agent"), .string("task")]),
            ]),
            overridesBuiltInTool: true,
            handler: { [weak self] args in
                guard let self else { return "SubAgentToolProvider deallocated" }
                return await self.handleRunSubAgent(args)
            }
        )
    }

    /// Build the report_progress tool for a specific sub-agent name.
    private func buildReportProgressTool(agentName: String, taskId: String?) -> ToolDefinition {
        let progressCallback = onProgress
        let reportsDir = workspaceURL.appendingPathComponent(".neo/reports/subagents", isDirectory: true)
        return ToolDefinition(
            name: "report_progress",
            description: "Report progress on the current task back to the parent agent. Use this for long-running tasks to keep the parent informed.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "status": .object([
                        "type": .string("string"),
                        "description": .string("Current status description"),
                    ]),
                ]),
                "required": .array([.string("status")]),
            ]),
            skipPermission: true,
            handler: { args in
                let status: String
                if case .object(let dict) = args, case .string(let s) = dict["status"] {
                    status = s
                } else {
                    status = String(describing: args)
                }
                logger.info("[\(agentName)] progress: \(status)")
                progressCallback?(agentName, status)

                // For async tasks, append progress to the report file
                if let taskId {
                    let reportFile = reportsDir.appendingPathComponent("\(taskId).md")
                    let line = "- [\(ISO8601DateFormatter().string(from: Date()))] \(status)\n"
                    if let handle = try? FileHandle(forWritingTo: reportFile) {
                        handle.seekToEndOfFile()
                        handle.write(line.data(using: .utf8) ?? Data())
                        handle.closeFile()
                    }
                }

                return "Progress reported."
            }
        )
    }

    /// Filter tools by the agent's frontmatter `tools` list.
    /// If frontmatter specifies tools, only include those + report_progress.
    /// If not specified, include all shared tools.
    private func filterTools(_ allTools: [ToolDefinition], allowedNames: [String]?) -> [ToolDefinition] {
        guard let allowedNames else { return allTools }
        let allowed = Set(allowedNames)
        return allTools.filter { allowed.contains($0.name) }
    }

    /// Directory for async sub-agent reports
    private var reportsDirectory: URL {
        workspaceURL.appendingPathComponent(".neo/reports/subagents", isDirectory: true)
    }

    private func handleRunSubAgent(_ args: JSONValue) async -> String {
        guard case .object(let dict) = args,
              case .string(let agentName) = dict["agent"],
              case .string(let task) = dict["task"] else {
            return "Error: 'agent' and 'task' are required"
        }

        let modelOverride: String?
        if case .string(let m) = dict["model"] { modelOverride = m } else { modelOverride = nil }

        let isAsync: Bool
        if case .bool(let a) = dict["async"] { isAsync = a } else { isAsync = false }

        // Load agent file or fall back to built-in default
        let frontmatter: AgentFrontmatter
        let body: String
        if let loaded = loadAgent(agentName) {
            frontmatter = loaded.frontmatter
            body = loaded.body
        } else {
            // Built-in fallback — no agent file needed, minimal tools
            logger.info("Agent '\(agentName)' not found on disk, using built-in default")
            frontmatter = AgentFrontmatter(tools: [])  // no tools for simple tasks
            body = "You are a helpful assistant. Complete the task thoroughly and concisely. Respond with just the result."
        }

        let model = modelOverride ?? frontmatter.model ?? "gpt-4.1-mini"

        if isAsync {
            return await runAsync(agentName: agentName, task: task, model: model, frontmatter: frontmatter, body: body)
        } else {
            return await runSync(agentName: agentName, task: task, model: model, frontmatter: frontmatter, body: body)
        }
    }

    /// Run sub-agent synchronously — blocks until complete.
    /// Sub-agents always use direct sessions (no loop tools).
    private func runSync(agentName: String, task: String, model: String, frontmatter: AgentFrontmatter, body: String) async -> String {
        logger.info("Starting sub-agent '\(agentName)' sync (model: \(model)) with task: \(task.prefix(100))")

        do {
            let transport = WebSocketTransport(host: relayHost, port: relayPort)
            let client = CopilotClient(transport: transport)
            try await client.start()
            logger.info("[SubAgent] client started, creating session...")

            var subAgentTools = filterTools(toolsBuilder(), allowedNames: frontmatter.tools)
            subAgentTools.append(buildReportProgressTool(agentName: agentName, taskId: nil))

            logger.info("[SubAgent] session tools: \(subAgentTools.map { $0.name }.joined(separator: ", "))")

            let config = SessionConfig(
                model: model,
                sessionId: "subagent-\(UUID().uuidString.lowercased())",
                tools: subAgentTools,
                systemMessage: .replace(body),
                appId: appId,
                userId: userId
            )

            let session = try await client.createSession(config: config)
            logger.info("[SubAgent] session created (id=\(session.sessionId.prefix(8))), sending prompt...")

            // Direct session: sendAndWait captures the assistant.message response directly
            let result = try await session.sendAndWait(prompt: task, timeout: 60)
                ?? "Sub-agent completed with no output"

            logger.info("[SubAgent] result: \(result.prefix(200))")
            try? await session.destroy()

            logger.info("Sub-agent '\(agentName)' completed: \(result.prefix(200))")
            return result

        } catch {
            logger.info("[SubAgent] error: \(error.localizedDescription)")
            logger.error("Sub-agent '\(agentName)' failed: \(error.localizedDescription)")
            return "Error running sub-agent '\(agentName)': \(error.localizedDescription)"
        }
    }

    /// Run sub-agent asynchronously — returns immediately with task ID,
    /// writes result to .neo/reports/subagents/{taskId}.md
    private func runAsync(agentName: String, task: String, model: String, frontmatter: AgentFrontmatter, body: String) async -> String {
        let taskId = "\(agentName)-\(Int(Date().timeIntervalSince1970))"

        // Create report file
        try? FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let reportFile = reportsDirectory.appendingPathComponent("\(taskId).md")
        let header = "# Sub-agent: \(agentName)\n\nTask: \(task)\nStarted: \(ISO8601DateFormatter().string(from: Date()))\nStatus: running\n\n## Progress\n"
        try? header.write(to: reportFile, atomically: true, encoding: .utf8)

        logger.info("Starting sub-agent '\(agentName)' async (taskId: \(taskId))")

        // Fire and forget
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runSync(
                agentName: agentName, task: task, model: model,
                frontmatter: frontmatter, body: body
            )

            // Write final result
            let footer = "\n## Result\n\n\(result)\n\nCompleted: \(ISO8601DateFormatter().string(from: Date()))\nStatus: completed\n"
            if let handle = try? FileHandle(forWritingTo: reportFile) {
                handle.seekToEndOfFile()
                handle.write(footer.data(using: .utf8) ?? Data())
                handle.closeFile()
            }

            // Update status line
            if let content = try? String(contentsOf: reportFile, encoding: .utf8) {
                let updated = content.replacingOccurrences(of: "Status: running", with: "Status: completed")
                try? updated.write(to: reportFile, atomically: true, encoding: .utf8)
            }

            self.onProgress?(agentName, "completed")
            logger.info("Async sub-agent '\(agentName)' (taskId: \(taskId)) completed")
        }

        return "Sub-agent '\(agentName)' started in background. Task ID: \(taskId)\nProgress/result will be written to: .neo/reports/subagents/\(taskId).md\nUse memory_read tool to check the report."
    }

    // MARK: - Public API for programmatic invocation

    /// Run a named agent programmatically (not via tool call).
    /// Used by ReportScheduler and other system triggers.
    public func runAgent(name: String, task: String, model: String? = nil) async -> String {
        guard let (frontmatter, body) = loadAgent(name) else {
            return "Error: agent '\(name)' not found"
        }
        let resolvedModel = model ?? frontmatter.model ?? "gpt-4.1-mini"
        return await runSync(agentName: name, task: task, model: resolvedModel, frontmatter: frontmatter, body: body)
    }
}

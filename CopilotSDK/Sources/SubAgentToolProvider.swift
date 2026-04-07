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

/// Provides the `run_sub_agent` tool that spawns a separate relay session
/// using a named agent's instructions, runs a task, and returns the result.
public final class SubAgentToolProvider: @unchecked Sendable {
    private let workspaceURL: URL
    private let relayHost: String
    private let relayPort: UInt16
    private let userId: String?
    private let toolsBuilder: @Sendable () -> [ToolDefinition]
    /// Callback for progress reports from sub-agents.
    public var onProgress: (@Sendable (_ agent: String, _ progress: String) -> Void)?

    /// - Parameters:
    ///   - workspaceURL: Root workspace directory (contains .github/agents/)
    ///   - relayHost: Relay server hostname
    ///   - relayPort: Relay server port
    ///   - userId: User ID for session routing
    ///   - toolsBuilder: Closure that builds shared tools (memory, file, etc.) for the sub-agent.
    ///                   Should NOT include run_sub_agent itself to prevent recursion.
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
            name: "run_sub_agent",
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
                ]),
                "required": .array([.string("agent"), .string("task")]),
            ]),
            handler: { [weak self] args in
                guard let self else { return "SubAgentToolProvider deallocated" }
                return await self.handleRunSubAgent(args)
            }
        )
    }

    /// Build the report_progress tool for a specific sub-agent name.
    private func buildReportProgressTool(agentName: String) -> ToolDefinition {
        let progressCallback = onProgress
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

    private func handleRunSubAgent(_ args: JSONValue) async -> String {
        guard case .object(let dict) = args,
              case .string(let agentName) = dict["agent"],
              case .string(let task) = dict["task"] else {
            return "Error: 'agent' and 'task' are required"
        }

        let modelOverride: String?
        if case .string(let m) = dict["model"] { modelOverride = m } else { modelOverride = nil }

        // Load agent file with frontmatter
        guard let (frontmatter, body) = loadAgent(agentName) else {
            let available = availableAgents()
            return "Error: agent '\(agentName)' not found. Available: \(available.joined(separator: ", "))"
        }

        let model = modelOverride ?? frontmatter.model ?? "gpt-4.1-mini"
        logger.info("Starting sub-agent '\(agentName)' (model: \(model)) with task: \(task.prefix(100))")

        do {
            // Create a separate WS connection for the sub-agent
            let transport = WebSocketTransport(host: relayHost, port: relayPort)
            let client = CopilotClient(transport: transport)
            try await client.start()

            // Build tools: filter by frontmatter, add report_progress
            var subAgentTools = filterTools(toolsBuilder(), allowedNames: frontmatter.tools)
            subAgentTools.append(buildReportProgressTool(agentName: agentName))

            let config = SessionConfig(
                model: model,
                tools: subAgentTools,
                systemMessage: .loop(body),
                userId: userId,
                agentId: agentName
            )

            let session = try await client.createSession(config: config)

            // Run the task and wait for result
            let result = try await session.sendAndWait(
                prompt: task,
                timeout: 180
            ) ?? "Sub-agent completed with no output"

            // Disconnect the sub-agent session
            try? await session.disconnect()

            logger.info("Sub-agent '\(agentName)' completed: \(result.prefix(200))")
            return result

        } catch {
            logger.error("Sub-agent '\(agentName)' failed: \(error.localizedDescription)")
            return "Error running sub-agent '\(agentName)': \(error.localizedDescription)"
        }
    }
}

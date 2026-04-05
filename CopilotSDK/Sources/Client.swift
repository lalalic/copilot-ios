import Foundation
import os

private let sdkLog = Logger(subsystem: "com.copilot.sdk", category: "session")

// MARK: - Session Event Types

/// All session event types from the official Copilot SDK protocol (40+ types).
/// See: https://github.com/github/copilot-sdk/blob/main/docs/features/streaming-events.md
public enum SessionEventType: String, Sendable {
    // Assistant events
    case assistantTurnStart = "assistant.turn_start"
    case assistantTurnEnd = "assistant.turn_end"
    case assistantIntent = "assistant.intent"
    case assistantReasoning = "assistant.reasoning"
    case assistantReasoningDelta = "assistant.reasoning_delta"
    case assistantMessage = "assistant.message"
    case assistantMessageDelta = "assistant.message_delta"
    case assistantUsage = "assistant.usage"
    case assistantStreamingDelta = "assistant.streaming_delta"

    // Tool execution events
    case toolUserRequested = "tool.user_requested"
    case toolExecutionStart = "tool.execution_start"
    case toolExecutionPartialResult = "tool.execution_partial_result"
    case toolExecutionProgress = "tool.execution_progress"
    case toolExecutionComplete = "tool.execution_complete"

    // Session lifecycle events
    case sessionStart = "session.start"
    case sessionIdle = "session.idle"
    case sessionError = "session.error"
    case sessionCompactionStart = "session.compaction_start"
    case sessionCompactionComplete = "session.compaction_complete"
    case sessionTitleChanged = "session.title_changed"
    case sessionContextChanged = "session.context_changed"
    case sessionUsageInfo = "session.usage_info"
    case sessionTaskComplete = "session.task_complete"
    case sessionShutdown = "session.shutdown"
    case sessionCustomAgentsUpdated = "session.custom_agents_updated"

    // Permission & user input events
    case permissionRequested = "permission.requested"
    case permissionCompleted = "permission.completed"
    case userInputRequested = "user_input.requested"
    case userInputCompleted = "user_input.completed"
    case elicitationRequested = "elicitation.requested"
    case elicitationCompleted = "elicitation.completed"

    // Sub-agent & skill events
    case subagentStarted = "subagent.started"
    case subagentCompleted = "subagent.completed"
    case subagentFailed = "subagent.failed"
    case subagentSelected = "subagent.selected"
    case subagentDeselected = "subagent.deselected"
    case skillInvoked = "skill.invoked"

    // External tool events
    case externalToolRequested = "external_tool.requested"
    case externalToolCompleted = "external_tool.completed"

    // Other events
    case abort = "abort"
    case userMessage = "user.message"
    case systemMessage = "system.message"
    case pendingMessagesModified = "pending_messages.modified"
    case commandQueued = "command.queued"
    case commandCompleted = "command.completed"
    case commandExecute = "command.execute"
    case exitPlanModeRequested = "exit_plan_mode.requested"
    case exitPlanModeCompleted = "exit_plan_mode.completed"

    // Credits events (Stripe webhook push)
    case creditsGrantCreated = "credits.grant_created"

    case unknown
}

// MARK: - Errors

/// Errors thrown by CopilotSDK operations
public enum CopilotError: Error, LocalizedError {
    case serverError(String)
    case connectionFailed(String)
    case timeout
    case noPendingQuestion

    public var errorDescription: String? {
        switch self {
        case .serverError(let message): return "Server error: \(message)"
        case .connectionFailed(let message): return "Connection failed: \(message)"
        case .timeout: return "Operation timed out"
        case .noPendingQuestion: return "No pending ask_user question to answer"
        }
    }
}

/// A session event dispatched by the Copilot CLI.
/// Includes the common envelope fields from the official protocol.
public struct SessionEvent: Sendable {
    public let type: SessionEventType
    public let rawType: String
    public let data: JSONValue
    public let id: String?
    public let timestamp: String?
    public let parentId: String?
    public let ephemeral: Bool

    public init(type: SessionEventType, rawType: String = "", data: JSONValue,
                id: String? = nil, timestamp: String? = nil,
                parentId: String? = nil, ephemeral: Bool = false) {
        self.type = type
        self.rawType = rawType
        self.data = data
        self.id = id
        self.timestamp = timestamp
        self.parentId = parentId
        self.ephemeral = ephemeral
    }

    /// Extract the event from a session.event notification params
    static func from(notificationParams: JSONValue) -> SessionEvent? {
        guard case .object(let params) = notificationParams,
              case .object(let event) = params["event"],
              case .string(let typeStr) = event["type"] else { return nil }

        let type = SessionEventType(rawValue: typeStr) ?? .unknown
        let data = event["data"] ?? .null
        let id: String? = if case .string(let s) = event["id"] { s } else { nil }
        let timestamp: String? = if case .string(let s) = event["timestamp"] { s } else { nil }
        let parentId: String? = if case .string(let s) = event["parentId"] { s } else { nil }
        let ephemeral: Bool = if case .bool(let b) = event["ephemeral"] { b } else { false }

        return SessionEvent(type: type, rawType: typeStr, data: data,
                            id: id, timestamp: timestamp, parentId: parentId, ephemeral: ephemeral)
    }
}

// MARK: - Message Send Mode (Steering & Queueing)

/// Controls how messages are delivered during an active turn.
public enum MessageMode: String, Sendable {
    /// Queue for next turn (default). Each queued message starts its own full turn.
    case enqueue = "enqueue"
    /// Inject into current turn (steering). Used to redirect the agent mid-turn.
    case immediate = "immediate"
}

/// Handler for session events.
public typealias SessionEventHandler = @Sendable (SessionEvent) -> Void

// MARK: - Tool Definition

/// A tool handler receives parsed arguments and returns a result string.
public typealias ToolHandler = @Sendable (JSONValue) async throws -> String

/// Defines a tool that can be called by the Copilot assistant.
/// Matches the official SDK Tool interface.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String?
    /// JSON Schema for parameters (passed as-is to CLI)
    public let parameters: JSONValue?
    public let handler: ToolHandler
    /// When true, indicates this tool overrides a built-in tool of the same name
    public let overridesBuiltInTool: Bool
    /// When true, the tool can execute without a permission prompt
    public let skipPermission: Bool

    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue? = nil,
        overridesBuiltInTool: Bool = false,
        skipPermission: Bool = false,
        handler: @escaping ToolHandler
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.overridesBuiltInTool = overridesBuiltInTool
        self.skipPermission = skipPermission
        self.handler = handler
    }

    /// Wire format sent to CLI in session.create
    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = ["name": .string(name)]
        if let description { dict["description"] = .string(description) }
        if let parameters { dict["parameters"] = parameters }
        if overridesBuiltInTool { dict["overridesBuiltInTool"] = .bool(true) }
        if skipPermission { dict["skipPermission"] = .bool(true) }
        return .object(dict)
    }
}

// MARK: - System Message Configuration

/// Controls how the system prompt is constructed.
/// Matches official @github/copilot-sdk SystemMessageConfig.
public enum SystemMessageConfig: Sendable {
    /// Append mode (default): SDK foundation + optional custom content appended after SDK-managed sections
    case append(String? = nil)
    /// Replace the entire system message with custom text (removes all SDK guardrails)
    case replace(String)
    /// Customize specific sections of the system message while preserving SDK structure.
    /// Available section IDs: identity, tone, tool_efficiency, environment_context,
    /// code_change_rules, guidelines, safety, tool_instructions, custom_instructions, last_instructions.
    case customize(sections: [String: SystemMessageSectionAction], content: String? = nil)
    /// Loop mode: instructs the agent to run in an infinite loop, never closing the turn.
    /// Uses the content as loop behavior instructions. The agent should use
    /// `send_response` tool to communicate results and `vscode_askQuestions` to get next input.
    case loop(String)

    /// Wire format for session.create params
    var wireFormat: JSONValue {
        switch self {
        case .append(let content):
            var dict: [String: JSONValue] = [:]
            if let content { dict["content"] = .string(content) }
            return .object(dict)
        case .replace(let text):
            return .object(["mode": .string("replace"), "content": .string(text)])
        case .customize(let sections, let content):
            var dict: [String: JSONValue] = ["mode": .string("customize")]
            var sects: [String: JSONValue] = [:]
            for (id, action) in sections {
                sects[id] = action.wireFormat
            }
            if !sects.isEmpty { dict["sections"] = .object(sects) }
            if let content { dict["content"] = .string(content) }
            return .object(dict)
        case .loop(let instructions):
            return .object(["mode": .string("replace"), "content": .string(instructions)])
        }
    }
}

/// Action for a system message section
public enum SystemMessageSectionAction: Sendable {
    case keep
    case remove
    case replace(content: String)
    case prepend(content: String)
    case append(content: String)

    var wireFormat: JSONValue {
        switch self {
        case .keep: return .object(["action": .string("keep")])
        case .remove: return .object(["action": .string("remove")])
        case .replace(let c): return .object(["action": .string("replace"), "content": .string(c)])
        case .prepend(let c): return .object(["action": .string("prepend"), "content": .string(c)])
        case .append(let c): return .object(["action": .string("append"), "content": .string(c)])
        }
    }
}

// MARK: - Session Hooks

/// Hook handlers for intercepting session lifecycle events.
// MARK: - Hook Input/Output Types

/// Input for onPreToolUse hook.
public struct PreToolUseInput: Sendable {
    public let toolName: String
    public let toolArgs: JSONValue
    public let rawData: JSONValue
}

/// Result from onPreToolUse hook.
public struct PreToolUseResult: Sendable {
    /// "allow", "deny", or "ask"
    public var permissionDecision: String
    /// Optionally modify tool arguments
    public var modifiedArgs: JSONValue?
    /// Extra context appended to the model's context
    public var additionalContext: String?

    public init(permissionDecision: String = "allow", modifiedArgs: JSONValue? = nil, additionalContext: String? = nil) {
        self.permissionDecision = permissionDecision
        self.modifiedArgs = modifiedArgs
        self.additionalContext = additionalContext
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = ["permissionDecision": .string(permissionDecision)]
        if let modifiedArgs { dict["modifiedArgs"] = modifiedArgs }
        if let additionalContext { dict["additionalContext"] = .string(additionalContext) }
        return .object(dict)
    }
}

/// Input for onPostToolUse hook.
public struct PostToolUseInput: Sendable {
    public let toolName: String
    public let result: JSONValue
    public let rawData: JSONValue
}

/// Result from onPostToolUse hook.
public struct PostToolUseResult: Sendable {
    public var additionalContext: String?

    public init(additionalContext: String? = nil) {
        self.additionalContext = additionalContext
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = [:]
        if let additionalContext { dict["additionalContext"] = .string(additionalContext) }
        return .object(dict)
    }
}

/// Input for onUserPromptSubmitted hook.
public struct UserPromptSubmittedInput: Sendable {
    public let prompt: String
    public let rawData: JSONValue
}

/// Result from onUserPromptSubmitted hook.
public struct UserPromptSubmittedResult: Sendable {
    public var modifiedPrompt: String?

    public init(modifiedPrompt: String? = nil) {
        self.modifiedPrompt = modifiedPrompt
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = [:]
        if let modifiedPrompt { dict["modifiedPrompt"] = .string(modifiedPrompt) }
        return .object(dict)
    }
}

/// Input for onSessionStart hook.
public struct SessionStartInput: Sendable {
    /// "startup", "resume", or "new"
    public let source: String
    public let rawData: JSONValue
}

/// Result from onSessionStart hook.
public struct SessionStartResult: Sendable {
    public var additionalContext: String?

    public init(additionalContext: String? = nil) {
        self.additionalContext = additionalContext
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = [:]
        if let additionalContext { dict["additionalContext"] = .string(additionalContext) }
        return .object(dict)
    }
}

/// Input for onSessionEnd hook.
public struct SessionEndInput: Sendable {
    public let reason: String
    public let rawData: JSONValue
}

/// Input for onErrorOccurred hook.
public struct ErrorOccurredInput: Sendable {
    public let errorContext: String
    public let error: String
    public let rawData: JSONValue
}

/// Result from onErrorOccurred hook.
public struct ErrorOccurredResult: Sendable {
    /// "retry", "skip", or "abort"
    public var errorHandling: String

    public init(errorHandling: String = "skip") {
        self.errorHandling = errorHandling
    }

    var wireFormat: JSONValue {
        .object(["errorHandling": .string(errorHandling)])
    }
}

// MARK: - Session Hooks

/// Session hook handlers matching the official SDK interface.
/// Each hook receives typed input and returns an optional typed result.
public struct SessionHooks: Sendable {
    /// Called before each tool execution. Can allow/deny or modify arguments.
    public var onPreToolUse: (@Sendable (PreToolUseInput) async -> PreToolUseResult?)?
    /// Called after each tool execution. Can modify results or add context.
    public var onPostToolUse: (@Sendable (PostToolUseInput) async -> PostToolUseResult?)?
    /// Called when user submits a prompt. Can modify the prompt.
    public var onUserPromptSubmitted: (@Sendable (UserPromptSubmittedInput) async -> UserPromptSubmittedResult?)?
    /// Called when a session starts or resumes.
    public var onSessionStart: (@Sendable (SessionStartInput) async -> SessionStartResult?)?
    /// Called when session ends.
    public var onSessionEnd: (@Sendable (SessionEndInput) async -> Void)?
    /// Called when an error occurs. Can retry/skip/abort.
    public var onErrorOccurred: (@Sendable (ErrorOccurredInput) async -> ErrorOccurredResult?)?

    public init(
        onPreToolUse: (@Sendable (PreToolUseInput) async -> PreToolUseResult?)? = nil,
        onPostToolUse: (@Sendable (PostToolUseInput) async -> PostToolUseResult?)? = nil,
        onUserPromptSubmitted: (@Sendable (UserPromptSubmittedInput) async -> UserPromptSubmittedResult?)? = nil,
        onSessionStart: (@Sendable (SessionStartInput) async -> SessionStartResult?)? = nil,
        onSessionEnd: (@Sendable (SessionEndInput) async -> Void)? = nil,
        onErrorOccurred: (@Sendable (ErrorOccurredInput) async -> ErrorOccurredResult?)? = nil
    ) {
        self.onPreToolUse = onPreToolUse
        self.onPostToolUse = onPostToolUse
        self.onUserPromptSubmitted = onUserPromptSubmitted
        self.onSessionStart = onSessionStart
        self.onSessionEnd = onSessionEnd
        self.onErrorOccurred = onErrorOccurred
    }

    var hasAny: Bool {
        onPreToolUse != nil || onPostToolUse != nil || onUserPromptSubmitted != nil ||
        onSessionStart != nil || onSessionEnd != nil || onErrorOccurred != nil
    }
}

// MARK: - MCP Server Configuration

/// Configuration for an MCP server.
public struct MCPServerConfig: Sendable {
    public let command: String?
    public let args: [String]?
    public let env: [String: String]?
    public let url: String?
    public let tools: [String]
    public let type: String?
    public let timeout: Int?

    public init(command: String? = nil, args: [String]? = nil, env: [String: String]? = nil,
                url: String? = nil, tools: [String] = ["*"], type: String? = nil, timeout: Int? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.tools = tools
        self.type = type
        self.timeout = timeout
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = [
            "tools": .array(tools.map { .string($0) })
        ]
        if let command { dict["command"] = .string(command) }
        if let args { dict["args"] = .array(args.map { .string($0) }) }
        if let env {
            dict["env"] = .object(env.mapValues { .string($0) })
        }
        if let url { dict["url"] = .string(url) }
        if let type { dict["type"] = .string(type) }
        if let timeout { dict["timeout"] = .int(timeout) }
        return .object(dict)
    }
}

// MARK: - Custom Agent Configuration

/// Configuration for a custom agent.
public struct CustomAgentConfig: Sendable {
    public let name: String
    public let description: String?
    public let systemMessage: String?

    public init(name: String, description: String? = nil, systemMessage: String? = nil) {
        self.name = name
        self.description = description
        self.systemMessage = systemMessage
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = ["name": .string(name)]
        if let description { dict["description"] = .string(description) }
        if let systemMessage { dict["systemMessage"] = .string(systemMessage) }
        return .object(dict)
    }
}

// MARK: - Command Definition

/// A slash command handler receives the command name and arguments.
public typealias CommandHandler = @Sendable (_ commandName: String, _ args: String) async throws -> Void

/// Defines a slash command for the TUI (e.g., /deploy staging).
public struct CommandDefinition: Sendable {
    public let name: String
    public let description: String?
    public let handler: CommandHandler

    public init(name: String, description: String? = nil, handler: @escaping CommandHandler) {
        self.name = name
        self.description = description
        self.handler = handler
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = ["name": .string(name)]
        if let description { dict["description"] = .string(description) }
        return .object(dict)
    }
}

// MARK: - Permission Handling

/// Information about a permission request from the CLI.
public struct PermissionRequest: Sendable {
    /// The kind of operation: "shell", "write", "read", "mcp", "custom-tool", "url", "memory", "hook"
    public let kind: String
    public let toolCallId: String?
    public let toolName: String?
    public let fileName: String?
    public let fullCommandText: String?
    public let requestId: String
    public let rawData: JSONValue
}

/// Result of a permission check.
public enum PermissionResult: String, Sendable {
    case approved = "approved"
    case deniedByUser = "denied-interactively-by-user"
    case deniedNoRule = "denied-no-approval-rule-and-could-not-request-from-user"
    case deniedByRules = "denied-by-rules"
    case deniedByContentPolicy = "denied-by-content-exclusion-policy"
    case noResult = "no-result"
}

/// Handler for permission requests. Return .approved to allow, or a denial reason.
public typealias PermissionHandler = @Sendable (PermissionRequest) async -> PermissionResult

/// Built-in permission handler that approves all requests.
public let approveAll: PermissionHandler = { _ in .approved }

// MARK: - User Input Request

/// Information about a user input request from the agent's ask_user tool.
public struct UserInputRequest: Sendable {
    public let question: String
    public let choices: [String]?
    public let allowFreeform: Bool
    public let requestId: String
}

/// Result of a user input request.
public struct UserInputResult: Sendable {
    public let answer: String
    public let wasFreeform: Bool

    public init(answer: String, wasFreeform: Bool = true) {
        self.answer = answer
        self.wasFreeform = wasFreeform
    }
}

/// Handler for user input requests.
public typealias UserInputHandler = @Sendable (UserInputRequest) async -> UserInputResult

// MARK: - Session Capabilities

/// Capabilities reported by the CLI host when a session is created.
public struct SessionCapabilities: Sendable {
    public let ui: UICapabilities?

    public struct UICapabilities: Sendable {
        public let elicitation: Bool
    }

    public init(ui: UICapabilities? = nil) {
        self.ui = ui
    }

    static func from(_ json: JSONValue?) -> SessionCapabilities {
        guard case .object(let dict) = json,
              case .object(let ui) = dict["ui"] else {
            return SessionCapabilities()
        }
        let elicitation = if case .bool(let b) = ui["elicitation"] { b } else { false }
        return SessionCapabilities(ui: .init(elicitation: elicitation))
    }
}

// MARK: - Infinite Session Configuration

/// Configuration for infinite sessions with automatic compaction.
public struct InfiniteSessionConfig: Sendable {
    public let enabled: Bool
    public let backgroundCompactionThreshold: Double?
    public let bufferExhaustionThreshold: Double?

    public init(enabled: Bool = true, backgroundCompactionThreshold: Double? = nil,
                bufferExhaustionThreshold: Double? = nil) {
        self.enabled = enabled
        self.backgroundCompactionThreshold = backgroundCompactionThreshold
        self.bufferExhaustionThreshold = bufferExhaustionThreshold
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = ["enabled": .bool(enabled)]
        if let t = backgroundCompactionThreshold { dict["backgroundCompactionThreshold"] = .double(t) }
        if let t = bufferExhaustionThreshold { dict["bufferExhaustionThreshold"] = .double(t) }
        return .object(dict)
    }
}

// MARK: - Provider Configuration (BYOK)

/// Configuration for a custom API provider (Bring Your Own Key).
public struct ProviderConfig: Sendable {
    /// Provider type: "openai", "azure", "anthropic"
    public let type: String?
    /// API endpoint URL (required). For Azure, just the host (no path).
    public let baseUrl: String?
    /// API key for authentication
    public let apiKey: String?
    /// Bearer token (takes precedence over apiKey)
    public let bearerToken: String?
    /// API format for OpenAI/Azure: "completions" or "responses"
    public let wireApi: String?
    /// Azure-specific configuration
    public let azure: AzureConfig?

    public struct AzureConfig: Sendable {
        public let apiVersion: String?
        public init(apiVersion: String? = nil) { self.apiVersion = apiVersion }
    }

    public init(type: String? = nil, baseUrl: String? = nil, apiKey: String? = nil,
                bearerToken: String? = nil, wireApi: String? = nil, azure: AzureConfig? = nil) {
        self.type = type; self.baseUrl = baseUrl; self.apiKey = apiKey
        self.bearerToken = bearerToken; self.wireApi = wireApi; self.azure = azure
    }

    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = [:]
        if let type { dict["type"] = .string(type) }
        if let baseUrl { dict["baseUrl"] = .string(baseUrl) }
        if let apiKey { dict["apiKey"] = .string(apiKey) }
        if let bearerToken { dict["bearerToken"] = .string(bearerToken) }
        if let wireApi { dict["wireApi"] = .string(wireApi) }
        if let azure, let v = azure.apiVersion {
            dict["azure"] = .object(["apiVersion": .string(v)])
        }
        return .object(dict)
    }
}

// MARK: - Session Metadata

/// Metadata about a persisted session, returned by listSessions().
public struct SessionMetadata: Sendable {
    public let sessionId: String
    public let startTime: String
    public let modifiedTime: String
    public let summary: String?
    public let isRemote: Bool
    public let context: SessionContext?
}

/// Working directory context from session creation.
public struct SessionContext: Sendable {
    public let cwd: String
    public let gitRoot: String?
    public let repository: String?
    public let branch: String?
}

// MARK: - Client Lifecycle Events

/// Event types emitted by the CopilotClient for session lifecycle changes.
public enum ClientLifecycleEventType: String, Sendable {
    case sessionCreated = "session.created"
    case sessionDeleted = "session.deleted"
    case sessionUpdated = "session.updated"
    case sessionForeground = "session.foreground"
    case sessionBackground = "session.background"
}

/// A client lifecycle event.
public struct ClientLifecycleEvent: Sendable {
    public let type: ClientLifecycleEventType
    public let sessionId: String
}

/// Connection state of the CopilotClient.
public enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case stopped
}

// MARK: - Session Configuration

/// Full session configuration matching the official SDK SessionConfig.
public struct SessionConfig: Sendable {
    public var model: String?
    public var sessionId: String?
    public var clientName: String?
    public var reasoningEffort: String?  // "low", "medium", "high", "xhigh"
    public var tools: [ToolDefinition]?
    public var systemMessage: SystemMessageConfig?
    public var availableTools: [String]?
    public var excludedTools: [String]?
    public var hooks: SessionHooks?
    public var workingDirectory: String?
    public var streaming: Bool?
    public var mcpServers: [String: MCPServerConfig]?
    public var customAgents: [CustomAgentConfig]?
    public var agent: String?
    public var skillDirectories: [String]?
    public var disabledSkills: [String]?
    public var provider: ProviderConfig?
    public var infiniteSessions: InfiniteSessionConfig?
    public var configDir: String?
    public var commands: [CommandDefinition]?
    /// Base64-encoded snapshot to restore on the server (relay v2).
    /// The relay extracts conversation context from the snapshot's events.jsonl
    /// and auto-injects it into the new session.
    public var snapshot: String?
    /// App/workspace identifier for relay routing (relay v2).
    /// Routes to a specific workspace's pool on the relay server.
    public var appId: String?
    /// APNs device token for push notifications (hex string).
    /// Sent with session.create so the relay can push to this device.
    public var deviceToken: String?
    /// APNs environment: "sandbox" or "production".
    public var apnsEnv: String?
    /// User identifier for multi-user routing.
    public var userId: String?
    public var onPermissionRequest: PermissionHandler?
    public var onUserInputRequest: UserInputHandler?
    public var onEvent: SessionEventHandler?

    public init(
        model: String? = nil,
        sessionId: String? = nil,
        clientName: String? = nil,
        reasoningEffort: String? = nil,
        tools: [ToolDefinition]? = nil,
        systemMessage: SystemMessageConfig? = nil,
        availableTools: [String]? = nil,
        excludedTools: [String]? = nil,
        hooks: SessionHooks? = nil,
        workingDirectory: String? = nil,
        streaming: Bool? = nil,
        mcpServers: [String: MCPServerConfig]? = nil,
        customAgents: [CustomAgentConfig]? = nil,
        agent: String? = nil,
        skillDirectories: [String]? = nil,
        disabledSkills: [String]? = nil,
        provider: ProviderConfig? = nil,
        infiniteSessions: InfiniteSessionConfig? = nil,
        configDir: String? = nil,
        commands: [CommandDefinition]? = nil,
        snapshot: String? = nil,
        appId: String? = nil,
        deviceToken: String? = nil,
        apnsEnv: String? = nil,
        userId: String? = nil,
        onPermissionRequest: PermissionHandler? = nil,
        onUserInputRequest: UserInputHandler? = nil,
        onEvent: SessionEventHandler? = nil
    ) {
        self.model = model
        self.sessionId = sessionId
        self.clientName = clientName
        self.reasoningEffort = reasoningEffort
        self.tools = tools
        self.systemMessage = systemMessage
        self.availableTools = availableTools
        self.excludedTools = excludedTools
        self.hooks = hooks
        self.workingDirectory = workingDirectory
        self.streaming = streaming
        self.mcpServers = mcpServers
        self.customAgents = customAgents
        self.agent = agent
        self.skillDirectories = skillDirectories
        self.disabledSkills = disabledSkills
        self.provider = provider
        self.infiniteSessions = infiniteSessions
        self.configDir = configDir
        self.commands = commands
        self.snapshot = snapshot
        self.appId = appId
        self.deviceToken = deviceToken
        self.apnsEnv = apnsEnv
        self.userId = userId
        self.onPermissionRequest = onPermissionRequest
        self.onUserInputRequest = onUserInputRequest
        self.onEvent = onEvent
    }

    /// Build the RPC params dictionary for session.create or session.resume
    func buildParams(sessionId: String) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["sessionId": .string(sessionId), "requestPermission": .bool(true)]
        if let model { p["model"] = .string(model) }
        if let clientName { p["clientName"] = .string(clientName) }
        if let reasoningEffort { p["reasoningEffort"] = .string(reasoningEffort) }
        if let tools { p["tools"] = .array(tools.map { $0.wireFormat }) }
        if let systemMessage { p["systemMessage"] = systemMessage.wireFormat }
        if let availableTools { p["availableTools"] = .array(availableTools.map { .string($0) }) }
        if let excludedTools { p["excludedTools"] = .array(excludedTools.map { .string($0) }) }
        if let hooks, hooks.hasAny { p["hooks"] = .bool(true) }
        if let workingDirectory { p["workingDirectory"] = .string(workingDirectory) }
        if let streaming { p["streaming"] = .bool(streaming) }
        if let mcpServers {
            p["mcpServers"] = .object(mcpServers.mapValues { $0.wireFormat })
            p["envValueMode"] = .string("direct")
        }
        if let customAgents { p["customAgents"] = .array(customAgents.map { $0.wireFormat }) }
        if let agent { p["agent"] = .string(agent) }
        if let skillDirectories { p["skillDirectories"] = .array(skillDirectories.map { .string($0) }) }
        if let disabledSkills { p["disabledSkills"] = .array(disabledSkills.map { .string($0) }) }
        if let provider { p["provider"] = provider.wireFormat }
        if let infiniteSessions { p["infiniteSessions"] = infiniteSessions.wireFormat }
        if let configDir { p["configDir"] = .string(configDir) }
        if let commands { p["commands"] = .array(commands.map { $0.wireFormat }) }
        if let snapshot { p["snapshot"] = .string(snapshot) }
        if let appId { p["appId"] = .string(appId) }
        if let deviceToken { p["deviceToken"] = .string(deviceToken) }
        if let apnsEnv { p["apnsEnv"] = .string(apnsEnv) }
        if let userId { p["userId"] = .string(userId) }
        return p
    }
}

// MARK: - Copilot Session

/// Represents an active Copilot CLI session, matching the official SDK protocol.

public final class CopilotSession: @unchecked Sendable {
    public let sessionId: String
    /// Capabilities reported by the CLI host.
    public internal(set) var capabilities: SessionCapabilities = SessionCapabilities()
    /// Workspace path for infinite sessions (contains checkpoints/, plan.md, files/).
    public internal(set) var workspacePath: String?

    // MARK: - Relay v2 Properties

    /// Whether this session was resumed from a pinned on-hold session (relay v2).
    public internal(set) var resumed: Bool = false
    /// The pending question from ask_user if the session was resumed while on-hold (relay v2).
    public internal(set) var pendingQuestion: String?
    /// The requestId for the pending ask_user tool call (relay v2).
    /// Use this to answer the pending question via `session.tools.handlePendingToolCall`.
    public internal(set) var pendingRequestId: String?
    /// Base64-encoded snapshot received from the relay's server-side cache (relay v2).
    /// Client should persist this locally for future reconnection.
    public internal(set) var snapshotData: String?
    /// Timestamp of the server-side snapshot (relay v2).
    public internal(set) var snapshotTimestamp: Int?
    /// Conversation context recovered from snapshot's events.jsonl (relay v2).
    /// The relay auto-injects this as the first prompt to the session.
    public internal(set) var recoveredContext: String?
    private let connection: JSONRPCConnection
    private var toolHandlers: [String: ToolHandler] = [:]
    private var commandHandlers: [String: CommandHandler] = [:]
    private var hooks: SessionHooks?
    private var permissionHandler: PermissionHandler?
    private var userInputHandler: UserInputHandler?
    private var eventTask: Task<Void, Never>?
    private let eventStore = EventHandlerStore()

    /// Handler for relay server notifications (usage, agent_progress, build status, etc.)
    /// Called on any JSON-RPC `notification` method message from the relay.
    public var onRelayNotification: ((_ type: String, _ params: [String: JSONValue]) -> Void)?

    init(sessionId: String, connection: JSONRPCConnection, config: SessionConfig? = nil, tools: [ToolDefinition]? = nil, hooks: SessionHooks? = nil) {
        self.sessionId = sessionId
        self.connection = connection
        self.hooks = hooks ?? config?.hooks
        self.permissionHandler = config?.onPermissionRequest
        self.userInputHandler = config?.onUserInputRequest

        // Register tool handlers
        let toolList = tools ?? config?.tools
        if let toolList {
            for tool in toolList {
                toolHandlers[tool.name] = tool.handler
            }
        }

        // Register command handlers
        if let commands = config?.commands {
            for cmd in commands {
                commandHandlers[cmd.name] = cmd.handler
            }
        }

        // Register hooks.invoke RPC handler (CLI sends hooks as JSON-RPC requests)
        let sessionHooks = self.hooks
        if let sessionHooks, sessionHooks.hasAny {
            connection.registerRequestHandler("hooks.invoke") { [weak self] params in
                guard let self, case .object(let dict) = params else {
                    return .object([:])
                }
                let hookId = dict["hookId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
                let data = dict["data"] ?? .object([:])
                let dataDict: [String: JSONValue] = if case .object(let d) = data { d } else { [:] }

                switch hookId {
                case "pre-tool-use":
                    if let handler = self.hooks?.onPreToolUse {
                        let input = PreToolUseInput(
                            toolName: dataDict["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                            toolArgs: dataDict["toolArgs"] ?? .null,
                            rawData: data
                        )
                        return await handler(input)?.wireFormat ?? .object([:])
                    }
                case "post-tool-use":
                    if let handler = self.hooks?.onPostToolUse {
                        let input = PostToolUseInput(
                            toolName: dataDict["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                            result: dataDict["result"] ?? .null,
                            rawData: data
                        )
                        return await handler(input)?.wireFormat ?? .object([:])
                    }
                case "user-prompt-submitted":
                    if let handler = self.hooks?.onUserPromptSubmitted {
                        let input = UserPromptSubmittedInput(
                            prompt: dataDict["prompt"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                            rawData: data
                        )
                        return await handler(input)?.wireFormat ?? .object([:])
                    }
                case "session-start":
                    if let handler = self.hooks?.onSessionStart {
                        let input = SessionStartInput(
                            source: dataDict["source"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                            rawData: data
                        )
                        return await handler(input)?.wireFormat ?? .object([:])
                    }
                case "session-end":
                    if let handler = self.hooks?.onSessionEnd {
                        let input = SessionEndInput(
                            reason: dataDict["reason"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                            rawData: data
                        )
                        await handler(input)
                    }
                case "error-occurred":
                    if let handler = self.hooks?.onErrorOccurred {
                        let input = ErrorOccurredInput(
                            errorContext: dataDict["errorContext"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                            error: dataDict["error"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                            rawData: data
                        )
                        return await handler(input)?.wireFormat ?? .object([:])
                    }
                default:
                    break
                }
                return .object([:])
            }
        }

        // Always start event dispatch to support on() subscriptions
        startEventDispatch()
    }

    // MARK: - Event Subscription

    /// Register a handler for all session events.
    public func on(_ handler: @escaping @Sendable (SessionEvent) -> Void) async {
        await eventStore.add(nil, handler)
    }

    /// Register a handler for a specific event type.
    public func on(_ eventType: SessionEventType, handler: @escaping @Sendable (SessionEvent) -> Void) async {
        await eventStore.add(eventType, handler)
    }

    // MARK: - Event Dispatch

    /// Start listening for broadcast events (tool calls, hooks, user subscriptions)
    private func startEventDispatch() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await notification in self.connection.notifications {
                NSLog("[CopilotSDK] Event dispatch: method=%@", notification.method)
                // Handle relay server notifications (usage, agent_progress, build status)
                if notification.method == "notification" {
                    if case .object(let params) = notification.params {
                        let type: String
                        if case .string(let t) = params["type"] { type = t } else { type = "unknown" }
                        NSLog("[CopilotSDK] Relay notification type=%@, hasHandler=%@", type, self.onRelayNotification != nil ? "yes" : "no")
                        self.onRelayNotification?(type, params)
                    }
                    continue
                }

                guard notification.method == "session.event",
                      case .object(let params) = notification.params,
                      case .object(let event) = params["event"],
                      case .string(let typeStr) = event["type"] else { continue }

                // Log key events
                if typeStr == "external_tool.requested" || typeStr == "session.idle" || typeStr == "assistant.turn_end" || typeStr == "session.error" {
                    sdkLog.info("📨 Event: \(typeStr)")
                }

                let data: [String: JSONValue]
                if case .object(let d) = event["data"] { data = d } else { data = [:] }

                // Dispatch to registered event handlers
                if let sessionEvent = SessionEvent.from(notificationParams: .object(params)) {
                    let handlers = await self.eventStore.getAll()
                    for (filterType, handler) in handlers {
                        if filterType == nil || filterType == sessionEvent.type {
                            handler(sessionEvent)
                        }
                    }
                }

                // Internal dispatch for tools, permissions, hooks, and commands
                switch typeStr {
                case "permission.requested":
                    if case .string(let requestId) = data["requestId"] {
                        let result: PermissionResult
                        if let handler = self.permissionHandler {
                            let request = PermissionRequest(
                                kind: data["kind"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "unknown",
                                toolCallId: data["toolCallId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                                toolName: data["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                                fileName: data["fileName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                                fullCommandText: data["fullCommandText"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                                requestId: requestId,
                                rawData: .object(data)
                            )
                            result = await handler(request)
                        } else {
                            result = .approved // Default: auto-approve
                        }
                        _ = try? await self.connection.send(
                            method: "session.permissions.handlePendingPermissionRequest",
                            params: [
                                "sessionId": .string(self.sessionId),
                                "requestId": .string(requestId),
                                "result": .object(["kind": .string(result.rawValue)]),
                            ]
                        )
                    }
                case "user_input.requested":
                    if case .string(let requestId) = data["requestId"],
                       let handler = self.userInputHandler {
                        let question = data["question"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
                        let choices: [String]? = data["choices"].flatMap {
                            if case .array(let arr) = $0 {
                                return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                            }
                            return nil
                        }
                        let allowFreeform = data["allowFreeform"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? true
                        let request = UserInputRequest(question: question, choices: choices, allowFreeform: allowFreeform, requestId: requestId)
                        let response = await handler(request)
                        _ = try? await self.connection.send(
                            method: "session.ui.elicitation",
                            params: [
                                "sessionId": .string(self.sessionId),
                                "requestId": .string(requestId),
                                "result": .object([
                                    "answer": .string(response.answer),
                                    "wasFreeform": .bool(response.wasFreeform),
                                ]),
                            ]
                        )
                    }
                case "command.execute":
                    if case .string(let commandName) = data["commandName"] {
                        let args = data["args"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
                        if let handler = self.commandHandlers[commandName] {
                            try? await handler(commandName, args)
                        }
                    }
                case "external_tool.requested":
                    // Spawn tool calls in a separate task to avoid blocking the event dispatch loop.
                    // This is critical because tools like ask_user block until user responds,
                    // which would prevent all subsequent notifications from being processed.
                    let selfRef = self
                    Task { await selfRef.handleToolCall(data) }
                case "hooks.pre_tool_use":
                    await self.handleHookEvent("pre_tool_use", data: data)
                case "hooks.post_tool_use":
                    await self.handleHookEvent("post_tool_use", data: data)
                case "hooks.user_prompt_submitted":
                    await self.handleHookEvent("user_prompt_submitted", data: data)
                case "hooks.session_start":
                    await self.handleHookEvent("session_start", data: data)
                case "hooks.session_end":
                    await self.handleHookEvent("session_end", data: data)
                case "hooks.error_occurred":
                    await self.handleHookEvent("error_occurred", data: data)
                default:
                    break
                }
            }
        }
    }

    /// Handle an external tool call from the CLI
    private func handleToolCall(_ data: [String: JSONValue]) async {
        guard case .string(let toolName) = data["toolName"],
              case .string(let requestId) = data["requestId"] else { return }

        let args = data["arguments"] ?? .null

        guard let handler = toolHandlers[toolName] else {
            NSLog("[CopilotSDK] No handler for tool '%@' — skipping", toolName)
            sdkLog.warning("⚠️ No handler for tool '\(toolName)' — skipping (requestId: \(requestId))")
            return
        }

        NSLog("[CopilotSDK] Tool call: %@ (requestId: %@)", toolName, String(requestId.prefix(8)))
        sdkLog.info("🔧 Tool call: \(toolName) (requestId: \(requestId.prefix(8))...)")

        do {
            let result = try await handler(args)
            NSLog("[CopilotSDK] Tool '%@' completed (%d chars)", toolName, result.count)
            sdkLog.info("✅ Tool '\(toolName)' completed (\(result.count) chars)")
            _ = try await connection.send(method: "session.tools.handlePendingToolCall", params: [
                "sessionId": .string(sessionId),
                "requestId": .string(requestId),
                "result": .string(result),
            ])
            NSLog("[CopilotSDK] Tool result sent for '%@'", toolName)
            sdkLog.info("📤 Tool result sent for '\(toolName)'")
        } catch {
            NSLog("[CopilotSDK] Tool '%@' error: %@", toolName, String(describing: error))
            sdkLog.error("❌ Tool '\(toolName)' error: \(error)")
            _ = try? await connection.send(method: "session.tools.handlePendingToolCall", params: [
                "sessionId": .string(sessionId),
                "requestId": .string(requestId),
                "error": .string(error.localizedDescription),
            ])
        }
    }

    /// Handle a hooks callback (event-based v1 protocol)
    private func handleHookEvent(_ hookId: String, data: [String: JSONValue]) async {
        guard let hooks else { return }
        guard case .string(let requestId) = data["requestId"] else { return }

        var resultValue: JSONValue = .object([:])
        switch hookId {
        case "pre_tool_use":
            if let handler = hooks.onPreToolUse {
                let input = PreToolUseInput(
                    toolName: data["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    toolArgs: data["toolArgs"] ?? .null,
                    rawData: .object(data)
                )
                resultValue = await handler(input)?.wireFormat ?? .object([:])
            }
        case "post_tool_use":
            if let handler = hooks.onPostToolUse {
                let input = PostToolUseInput(
                    toolName: data["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    result: data["result"] ?? .null,
                    rawData: .object(data)
                )
                resultValue = await handler(input)?.wireFormat ?? .object([:])
            }
        case "user_prompt_submitted":
            if let handler = hooks.onUserPromptSubmitted {
                let input = UserPromptSubmittedInput(
                    prompt: data["prompt"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    rawData: .object(data)
                )
                resultValue = await handler(input)?.wireFormat ?? .object([:])
            }
        case "session_start":
            if let handler = hooks.onSessionStart {
                let input = SessionStartInput(
                    source: data["source"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    rawData: .object(data)
                )
                resultValue = await handler(input)?.wireFormat ?? .object([:])
            }
        case "session_end":
            if let handler = hooks.onSessionEnd {
                let input = SessionEndInput(
                    reason: data["reason"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    rawData: .object(data)
                )
                await handler(input)
            }
        case "error_occurred":
            if let handler = hooks.onErrorOccurred {
                let input = ErrorOccurredInput(
                    errorContext: data["errorContext"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    error: data["error"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    rawData: .object(data)
                )
                resultValue = await handler(input)?.wireFormat ?? .object([:])
            }
        default:
            return
        }

        _ = try? await connection.send(method: "hooks.handleResponse", params: [
            "requestId": .string(requestId),
            "result": resultValue,
        ])
    }

    // MARK: - Send

    /// Send a text prompt to the session.
    @discardableResult
    public func send(prompt: String, attachments: [JSONValue]? = nil, mode: MessageMode = .enqueue) async throws -> JSONValue {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "prompt": .string(prompt),
            "mode": .string(mode.rawValue),
        ]
        if let attachments {
            params["attachments"] = .array(attachments)
        }
        return try await connection.send(method: "session.send", params: params)
    }

    /// Send a text prompt and wait for the AI's response (waits for session.idle event).
    /// Returns the final assistant message content.
    public func sendAndWait(prompt: String, attachments: [JSONValue]? = nil, mode: MessageMode = .enqueue, timeout: TimeInterval = 60) async throws -> String? {
        let waiter = SendWaiter()

        // Register temporary event handlers via on()
        await self.on(.assistantMessage) { event in
            if case .object(let data) = event.data,
               case .string(let content) = data["content"] {
                Task { await waiter.setContent(content) }
            }
        }

        await self.on(.sessionIdle) { _ in
            Task { await waiter.complete() }
        }

        await self.on(.sessionError) { _ in
            Task { await waiter.complete() }
        }

        // Send the prompt
        _ = try await send(prompt: prompt, attachments: attachments, mode: mode)

        // Wait for completion or timeout
        let waitTask = Task { await waiter.waitForCompletion() }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            await waiter.complete()
        }

        await waitTask.value
        timeoutTask.cancel()

        return await waiter.content
    }

    /// Send a multimodal prompt with image + text.
    @discardableResult
    public func sendWithImage(_ imageBase64: String, mimeType: String, text: String, mode: MessageMode = .enqueue) async throws -> JSONValue {
        let attachment: JSONValue = .object([
            "type": .string("blob"),
            "data": .string(imageBase64),
            "mimeType": .string(mimeType),
        ])
        return try await send(prompt: text, attachments: [attachment], mode: mode)
    }

    /// Send an image prompt and wait for the AI's response.
    public func sendWithImageAndWait(_ imageBase64: String, mimeType: String, text: String, mode: MessageMode = .enqueue, timeout: TimeInterval = 60) async throws -> String? {
        let attachment: JSONValue = .object([
            "type": .string("blob"),
            "data": .string(imageBase64),
            "mimeType": .string(mimeType),
        ])
        return try await sendAndWait(prompt: text, attachments: [attachment], mode: mode, timeout: timeout)
    }

    /// Send a prompt with a file attachment.
    @discardableResult
    public func sendWithFile(path: String, displayName: String? = nil, text: String, mode: MessageMode = .enqueue) async throws -> JSONValue {
        var attachment: [String: JSONValue] = [
            "type": .string("file"),
            "path": .string(path),
        ]
        if let displayName { attachment["displayName"] = .string(displayName) }
        return try await send(prompt: text, attachments: [.object(attachment)], mode: mode)
    }

    // MARK: - Session History

    /// Get all events/messages from this session.
    public func getMessages() async throws -> [SessionEvent] {
        let result = try await connection.send(method: "session.getMessages", params: [
            "sessionId": .string(sessionId),
        ])
        guard case .array(let items) = result else { return [] }
        return items.compactMap { item -> SessionEvent? in
            guard case .object(let dict) = item,
                  case .string(let typeStr) = dict["type"] else { return nil }
            let type = SessionEventType(rawValue: typeStr) ?? .unknown
            return SessionEvent(type: type, rawType: typeStr, data: item)
        }
    }

    // MARK: - Steering & Control

    /// Steer the current turn by injecting an immediate message.
    @discardableResult
    public func steer(prompt: String) async throws -> JSONValue {
        try await send(prompt: prompt, mode: .immediate)
    }

    /// Abort the current session turn.
    public func abort() async throws {
        _ = try await connection.send(method: "session.abort", params: [
            "sessionId": .string(sessionId),
        ])
    }

    // MARK: - Response Methods

    /// Respond to a permission request.
    public func respondToPermission(requestId: String, approved: Bool) async throws {
        _ = try await connection.send(method: "session.permissions.handlePendingPermissionRequest", params: [
            "sessionId": .string(sessionId),
            "requestId": .string(requestId),
            "result": .object(["kind": .string(approved ? "approved" : "denied-no-approval-rule-and-could-not-request-from-user")]),
        ])
    }

    /// Respond to a user input request (elicitation).
    public func respondToUserInput(requestId: String, value: JSONValue) async throws {
        _ = try await connection.send(method: "session.ui.elicitation", params: [
            "sessionId": .string(sessionId),
            "requestId": .string(requestId),
            "result": value,
        ])
    }

    /// Respond to an external tool call.
    public func respondToExternalTool(requestId: String, result: String) async throws {
        _ = try await connection.send(method: "session.tools.handlePendingToolCall", params: [
            "sessionId": .string(sessionId),
            "requestId": .string(requestId),
            "result": .string(result),
        ])
    }

    /// Answer the pending ask_user question from a resumed on-hold session (relay v2).
    /// Call this after `createSession` returns `session.resumed == true` with a `pendingRequestId`.
    ///
    /// ```swift
    /// let session = try await client.createSession(config: config)
    /// if session.resumed, let requestId = session.pendingRequestId {
    ///     try await session.answerPendingQuestion(answer: "Continue with the task")
    /// }
    /// ```
    public func answerPendingQuestion(answer: String) async throws {
        guard let requestId = pendingRequestId else {
            throw CopilotError.noPendingQuestion
        }
        try await respondToExternalTool(requestId: requestId, result: answer)
        pendingQuestion = nil
        pendingRequestId = nil
    }

    // MARK: - UI Elicitation

    /// Convenience methods for interactive UI dialogs (requires elicitation capability).
    public struct UIApi {
        let session: CopilotSession

        /// Show a confirmation dialog. Returns true if user accepts.
        public func confirm(_ message: String) async throws -> Bool {
            let result = try await elicitation(message: message, schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "confirmed": .object(["type": .string("boolean")]),
                ]),
            ]))
            if case .object(let dict) = result,
               case .string(let action) = dict["action"] {
                return action == "accept"
            }
            return false
        }

        /// Show a selection dialog. Returns the selected value or nil.
        public func select(_ message: String, options: [String]) async throws -> String? {
            let result = try await elicitation(message: message, schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "selection": .object([
                        "type": .string("string"),
                        "enum": .array(options.map { .string($0) }),
                    ]),
                ]),
                "required": .array([.string("selection")]),
            ]))
            if case .object(let dict) = result,
               case .string(let action) = dict["action"], action == "accept",
               case .object(let content) = dict["content"],
               case .string(let selection) = content["selection"] {
                return selection
            }
            return nil
        }

        /// Show a text input dialog. Returns the input or nil.
        public func input(_ message: String, title: String? = nil, minLength: Int? = nil, maxLength: Int? = nil) async throws -> String? {
            var props: [String: JSONValue] = ["type": .string("string")]
            if let minLength { props["minLength"] = .int(minLength) }
            if let maxLength { props["maxLength"] = .int(maxLength) }

            var schema: [String: JSONValue] = [
                "type": .string("object"),
                "properties": .object(["value": .object(props)]),
                "required": .array([.string("value")]),
            ]
            if let title { schema["title"] = .string(title) }

            let result = try await elicitation(message: message, schema: .object(schema))
            if case .object(let dict) = result,
               case .string(let action) = dict["action"], action == "accept",
               case .object(let content) = dict["content"],
               case .string(let value) = content["value"] {
                return value
            }
            return nil
        }

        /// Generic elicitation with full schema control.
        public func elicitation(message: String, schema: JSONValue) async throws -> JSONValue {
            try await session.connection.send(method: "session.ui.elicitation", params: [
                "sessionId": .string(session.sessionId),
                "message": .string(message),
                "requestedSchema": schema,
            ])
        }
    }

    /// Interactive UI methods (only available when capabilities.ui.elicitation is true).
    public var ui: UIApi { UIApi(session: self) }

    // MARK: - Session Lifecycle

    /// Disconnect this session, preserving state on disk for later resume.
    public func disconnect() async throws {
        eventTask?.cancel()
        eventTask = nil
        _ = try await connection.send(method: "session.disconnect", params: [
            "sessionId": .string(sessionId),
        ])
    }

    /// Destroy this session permanently, removing all persisted state.
    public func destroy() async throws {
        eventTask?.cancel()
        eventTask = nil
        _ = try await connection.send(method: "session.destroy", params: [
            "sessionId": .string(sessionId),
        ])
    }

    /// Change the model for this session.
    public func setModel(_ model: String, reasoningEffort: String? = nil) async throws {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "modelId": .string(model),
        ]
        if let reasoningEffort { params["reasoningEffort"] = .string(reasoningEffort) }
        _ = try await connection.send(method: "session.model.switchTo", params: params)
    }

    // MARK: - Loop Mode

    /// Current state of a loop session.
    public enum LoopState: Sendable {
        /// A tool is running; user input will be steered when submitted
        case toolRunning
        /// Waiting for user input via ask_questions tool
        case waitingForInput
        /// Session is idle (turn ended)
        case idle
    }

    /// Run the session in an auto-resuming loop.
    ///
    /// The agent runs autonomously using tools. When a turn ends (session.idle),
    /// the `onTurnEnd` callback is called. Return a resume prompt to continue
    /// the loop, or `nil` to stop.
    ///
    /// The client controls the loop by providing `send_response` and `ask_questions`
    /// tools via the session config. The SDK manages auto-resume on turn end.
    ///
    /// - Parameters:
    ///   - initialPrompt: The first prompt to start the loop
    ///   - onTurnEnd: Called when a turn completes. Return a prompt to resume, or nil to stop.
    public func loop(
        initialPrompt: String?,
        onTurnEnd: @escaping @Sendable (CopilotSession) async -> String?
    ) async throws {
        let loopControl = LoopControl()
        // Thread-safe error flag set synchronously in event handler (no Task race)
        let errorFlag = LoopErrorFlag()

        // Monitor session state
        await self.on(.assistantTurnStart) { _ in
            Task { await loopControl.setState(.toolRunning) }
        }

        await self.on(.sessionIdle) { _ in
            Task { await loopControl.setState(.idle) }
        }

        // Detect fatal errors (quota, auth) and break the loop
        await self.on(.sessionError) { [errorFlag] event in
            if case .object(let data) = event.data {
                let errorType: String? = if case .string(let s) = data["errorType"] { s } else { nil }
                let message: String = if case .string(let s) = data["message"] { s } else { "Unknown error" }
                let statusCode: Int = if case .int(let n) = data["statusCode"] { n } else { 0 }

                // Break loop for quota (402) or auth (401) errors
                if errorType == "quota" || statusCode == 402 || statusCode == 401 {
                    print("[CopilotAgent] Fatal error: \(message). Stopping loop.")
                    // Set flag synchronously (no race) then unblock waitForIdle via actor
                    errorFlag.set(message)
                    Task { await loopControl.setFatalError(message) }
                }
            }
        }

        // Send initial prompt (skip if nil — e.g., when resuming a session
        // where the model is already running after answering a pending ask_user)
        if let initialPrompt {
            _ = try await send(prompt: initialPrompt)
        }

        // Loop: wait for idle, then decide to resume or stop
        while true {
            await loopControl.waitForIdle()

            // Brief delay to allow pending error events to be dispatched
            // (session.error may arrive just after session.idle in the same batch)
            try await Task.sleep(for: .milliseconds(50))

            // Check for fatal errors (both sync flag and actor for race safety)
            if let error = errorFlag.value {
                throw CopilotError.serverError(error)
            }
            if let error = await loopControl.fatalError {
                throw CopilotError.serverError(error)
            }

            // Ask client whether to continue
            if let resumePrompt = await onTurnEnd(self) {
                await loopControl.setState(.toolRunning)
                _ = try await send(prompt: resumePrompt)
            } else {
                break
            }
        }
    }

    /// Set the loop state to waitingForInput (called by ask_questions tool handler)
    public func setWaitingForInput() async {
        // This is a convenience for tool handlers to signal state
    }
}

/// Thread-safe error flag for synchronous access from event handlers.
/// Avoids race between session.idle and session.error event dispatch.
private final class LoopErrorFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ error: String) {
        lock.lock()
        _value = error
        lock.unlock()
    }
}

/// Internal actor to manage loop state
private actor LoopControl {
    var state: CopilotSession.LoopState = .toolRunning
    var fatalError: String?
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    func setState(_ newState: CopilotSession.LoopState) {
        state = newState
        if newState == .idle {
            let continuations = idleContinuations
            idleContinuations = []
            for c in continuations { c.resume() }
        }
    }

    func setFatalError(_ message: String) {
        fatalError = message
        state = .idle
        let continuations = idleContinuations
        idleContinuations = []
        for c in continuations { c.resume() }
    }

    public func waitForIdle() async {
        if state == .idle { return }
        await withCheckedContinuation { continuation in
            idleContinuations.append(continuation)
        }
    }
}

// MARK: - Copilot Agent

/// Configuration for creating an autonomous agent.
public struct AgentConfig: Sendable {
    /// Model to use (e.g. "gpt-4.1", "claude-sonnet-4").
    public var model: String?
    /// System instructions for the agent.
    /// When `sections` is nil, this replaces the entire system message (`.loop` mode).
    /// When `sections` is set, this becomes additional content appended after all sections (`.customize` mode).
    public var instructions: String
    /// Customize specific sections of the system prompt while preserving SDK defaults.
    /// Available section IDs: identity, tone, tool_efficiency, environment_context,
    /// code_change_rules, guidelines, safety, tool_instructions, custom_instructions, last_instructions.
    /// When set, the agent loop instructions are auto-injected into `last_instructions`.
    /// Example: `["identity": .replace(content: "You are Piggy, a toy pig companion")]`
    public var sections: [String: SystemMessageSectionAction]?
    /// Additional tools the agent can use (send_response and ask_user are auto-injected).
    public var tools: [ToolDefinition]
    /// Called when the agent uses send_response to deliver a result.
    public var onResponse: @Sendable (String) async -> Void
    /// Called when the agent uses ask_user to request input. Return the user's answer.
    public var onAskUser: @Sendable (String) async -> String
    /// Called when the agent uses ask_questions to request structured input.
    /// Return a JSON object keyed by question header.
    public var onAskQuestions: (@Sendable (JSONValue) async -> JSONValue)?
    /// Optional working directory for the agent.
    public var workingDirectory: String?
    /// Base64-encoded snapshot for relay v2 context recovery.
    public var snapshot: String?
    /// App/workspace identifier for relay v2 routing.
    public var appId: String?
    /// APNs device token for push notifications (hex string).
    public var deviceToken: String?
    /// APNs environment: "sandbox" or "production".
    public var apnsEnv: String?
    /// User identifier for multi-user routing.
    public var userId: String?

    public init(
        model: String? = nil,
        instructions: String,
        sections: [String: SystemMessageSectionAction]? = nil,
        tools: [ToolDefinition] = [],
        workingDirectory: String? = nil,
        snapshot: String? = nil,
        appId: String? = nil,
        deviceToken: String? = nil,
        apnsEnv: String? = nil,
        userId: String? = nil,
        onResponse: @escaping @Sendable (String) async -> Void,
        onAskUser: @escaping @Sendable (String) async -> String,
        onAskQuestions: (@Sendable (JSONValue) async -> JSONValue)? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.sections = sections
        self.tools = tools
        self.workingDirectory = workingDirectory
        self.snapshot = snapshot
        self.appId = appId
        self.deviceToken = deviceToken
        self.apnsEnv = apnsEnv
        self.userId = userId
        self.onResponse = onResponse
        self.onAskUser = onAskUser
        self.onAskQuestions = onAskQuestions
    }
}

/// An autonomous agent that runs in an infinite loop, delivering responses
/// via `send_response` tool and asking for user input via `ask_user` tool.
public final class CopilotAgent: @unchecked Sendable {
    public let session: CopilotSession
    private let config: AgentConfig
    private var _isRunning = false

    public var isRunning: Bool { _isRunning }

    init(session: CopilotSession, config: AgentConfig) {
        self.session = session
        self.config = config
    }

    /// Start the agent with an initial prompt. Blocks until the agent stops.
    ///
    /// If the session was resumed from the relay with a pending question,
    /// the agent answers it instead of sending a new initial prompt.
    public func start(prompt: String) async throws {
        _isRunning = true
        defer { _isRunning = false }

        if session.resumed, let requestId = session.pendingRequestId {
            // Session was on-hold with a pending ask_user. Answer it to resume the model.
            try await session.respondToExternalTool(
                requestId: requestId,
                result: "User reconnected. Context: \(prompt)"
            )
            // Enter the loop without sending an initial prompt (model is already running)
            try await session.loop(initialPrompt: nil) { [weak self] _ in
                guard self?._isRunning == true else { return nil }
                return "Continue working. Use send_response when you have results, or ask_user if you need input."
            }
        } else {
            try await session.loop(initialPrompt: prompt) { [weak self] _ in
                guard self?._isRunning == true else { return nil }
                return "Continue working. Use send_response when you have results, or ask_user if you need input."
            }
        }
    }

    /// Stop the agent after the current turn completes.
    public func stop() {
        _isRunning = false
    }

    /// Build the auto-injected tools for the agent pattern.
    static func buildTools(config: AgentConfig) -> [ToolDefinition] {
        var tools = config.tools

        let onResponse = config.onResponse
        tools.append(ToolDefinition(
            name: "send_response",
            description: "Send a response message to the user. Use this to deliver results instead of ending your turn.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("The response message to send to the user"),
                    ]),
                ]),
                "required": .array([.string("message")]),
            ]),
            skipPermission: true,
            handler: { args in
                let message: String
                if case .object(let dict) = args, case .string(let msg) = dict["message"] {
                    message = msg
                } else if case .string(let msg) = args {
                    message = msg
                } else {
                    message = String(describing: args)
                }
                await onResponse(message)
                return "Response delivered to user. Now call ask_user to wait for the user's next message. Do NOT call any other tools or send_response again."
            }
        ))

        let onAskUser = config.onAskUser
        let onAskQuestions = config.onAskQuestions
        tools.append(ToolDefinition(
            name: "ask_user",
            description: "Ask the user a question and wait for their answer. Use this when you need more information or when all tasks are completed to ask what to do next.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "question": .object([
                        "type": .string("string"),
                        "description": .string("The question to ask the user"),
                    ]),
                ]),
                "required": .array([.string("question")]),
            ]),
            skipPermission: true,
            handler: { args in
                let question: String
                if case .object(let dict) = args, case .string(let q) = dict["question"] {
                    question = q
                } else if case .string(let q) = args {
                    question = q
                } else {
                    question = "What would you like me to do next?"
                }
                let answer = await onAskUser(question)
                return "User answered: \(answer)"
            }
        ))

        tools.append(ToolDefinition(
            name: "ask_questions",
            description: "Ask one or more structured questions with options and optional free-form input, then wait for the user's answers.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "questions": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "header": .object([
                                    "type": .string("string"),
                                    "description": .string("A short label for this question"),
                                ]),
                                "question": .object([
                                    "type": .string("string"),
                                    "description": .string("The full question text"),
                                ]),
                                "multiSelect": .object([
                                    "type": .string("boolean"),
                                    "description": .string("Whether multiple options can be selected"),
                                ]),
                                "options": .object([
                                    "type": .string("array"),
                                    "items": .object([
                                        "type": .string("object"),
                                        "properties": .object([
                                            "label": .object([
                                                "type": .string("string"),
                                            ]),
                                            "description": .object([
                                                "type": .string("string"),
                                            ]),
                                            "recommended": .object([
                                                "type": .string("boolean"),
                                            ]),
                                        ]),
                                        "required": .array([.string("label")]),
                                    ]),
                                ]),
                                "allowFreeformInput": .object([
                                    "type": .string("boolean"),
                                    "description": .string("Allow free text input in addition to options"),
                                ]),
                            ]),
                            "required": .array([.string("header"), .string("question")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("questions")]),
            ]),
            skipPermission: true,
            handler: { args in
                if let onAskQuestions {
                    let result = await onAskQuestions(args)
                    if let data = try? JSONEncoder().encode(result), let text = String(data: data, encoding: .utf8) {
                        return "User answered: \(text)"
                    }
                    return "User answered."
                }

                let question: String
                if case .object(let dict) = args,
                   case .array(let arr) = dict["questions"],
                   case .object(let first) = arr.first,
                   case .string(let text) = first["question"] {
                    question = text
                } else {
                    question = "What would you like me to do next?"
                }
                let answer = await onAskUser(question)
                return "User answered: \(answer)"
            }
        ))

        return tools
    }

    /// Build the session config for an agent.
    static func buildSessionConfig(config: AgentConfig) -> SessionConfig {
        let agentLoopSuffix = """
        IMPORTANT: You are an autonomous agent running in an infinite loop.
        - Use the `send_response` tool to deliver your responses to the user. Do NOT just end your turn.
        - Use the `ask_user` tool when you need more information or when all tasks are done to ask what to do next.
        - Use the `ask_questions` tool when you need structured choices (single-select, multi-select, or free-form answers).
        - Always use one of these tools before your turn ends.
        """

        let systemMessage: SystemMessageConfig?
        if let sections = config.sections {
            // Customize mode: preserve SDK defaults, override specific sections.
            // Inject agent loop instructions into last_instructions (unless caller already set it).
            var allSections = sections
            if allSections["last_instructions"] == nil {
                allSections["last_instructions"] = .replace(content: agentLoopSuffix)
            }
            // instructions becomes the additional content appended after all sections.
            let content = config.instructions.isEmpty ? nil : config.instructions
            systemMessage = .customize(sections: allSections, content: content)
        } else if config.instructions.isEmpty {
            // No instructions and no sections — let the server (relay workspace) provide the system prompt.
            // The relay will use the workspace's main.agent.md if available.
            systemMessage = nil
        } else {
            // Legacy mode: flat instructions replace the entire system message.
            let agentSystemMessage = """
            \(config.instructions)

            \(agentLoopSuffix)
            """
            systemMessage = .loop(agentSystemMessage)
        }

        return SessionConfig(
            model: config.model,
            tools: buildTools(config: config),
            systemMessage: systemMessage,
            workingDirectory: config.workingDirectory,
            infiniteSessions: InfiniteSessionConfig(enabled: true),
            snapshot: config.snapshot,
            appId: config.appId,
            deviceToken: config.deviceToken,
            apnsEnv: config.apnsEnv,
            userId: config.userId
        )
    }
}

// MARK: - Copilot Client

/// High-level client for the Copilot CLI, matching the official SDK protocol.
/// Protocol flow: ping → session.create → session.send → session.event notifications
public final class CopilotClient: @unchecked Sendable {

    private let connection: JSONRPCConnection
    public private(set) var protocolVersion: Int = 0
    private var state: ConnectionState = .disconnected
    private let clientEventStore = ClientEventHandlerStore()

    public init(transport: Transport) {
        self.connection = JSONRPCConnection(transport: transport, framingMode: .contentLength)
    }

    /// Get the current connection state.
    public func getState() -> ConnectionState { state }

    /// Start the connection and verify protocol version via ping.
    public func start() async throws {
        state = .connecting
        try await connection.start()

        let result = try await connection.send(method: "ping", params: [
            "message": .string("hello"),
        ])

        if case .object(let dict) = result,
           case .int(let version) = dict["protocolVersion"] {
            protocolVersion = version
        }
        state = .connected
    }

    /// Send a raw JSON-RPC notification (no id, no response expected).
    public func sendNotification(method: String, params: [String: JSONValue]) async {
        do {
            try await connection.sendNotification(method: method, params: params)
        } catch {
            NSLog("[CopilotClient] sendNotification error: \(error.localizedDescription)")
        }
    }

    /// Send device token to relay for APNs push notifications.
    public func setDeviceToken(_ token: String, apnsEnv: String? = nil, userId: String? = nil) async {
        do {
            var params: [String: JSONValue] = ["token": .string(token)]
            if let apnsEnv { params["apnsEnv"] = .string(apnsEnv) }
            if let userId { params["userId"] = .string(userId) }
            try await connection.sendNotification(method: "set_device_token", params: params)
            NSLog("[CopilotClient] Sent device token to relay: \(token.prefix(8))...")
        } catch {
            NSLog("[CopilotClient] setDeviceToken error: \(error.localizedDescription)")
        }
    }

    /// Create a new session with full configuration.
    public func createSession(config: SessionConfig = SessionConfig()) async throws -> CopilotSession {
        let sessionId = config.sessionId ?? UUID().uuidString.lowercased()
        let params = config.buildParams(sessionId: sessionId)

        // Register permission.request v2 RPC handler
        let permHandler = config.onPermissionRequest
        connection.registerRequestHandler("permission.request") { params in
            if let permHandler, case .object(let dict) = params {
                let request = PermissionRequest(
                    kind: dict["kind"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "unknown",
                    toolCallId: dict["toolCallId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                    toolName: dict["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                    fileName: dict["fileName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                    fullCommandText: dict["fullCommandText"].flatMap { if case .string(let s) = $0 { return s } else { return nil } },
                    requestId: dict["requestId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    rawData: params ?? .null
                )
                let result = await permHandler(request)
                return .object(["result": .object(["kind": .string(result.rawValue)])])
            }
            return .object(["result": .object(["kind": .string("approved")])])
        }

        // Register userInput.request v2 RPC handler
        if let userInputHandler = config.onUserInputRequest {
            connection.registerRequestHandler("userInput.request") { params in
                guard case .object(let dict) = params else { return .object([:]) }
                let question = dict["question"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
                let choices: [String]? = dict["choices"].flatMap {
                    if case .array(let arr) = $0 { return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } } }
                    return nil
                }
                let allowFreeform = dict["allowFreeform"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? true
                let requestId = dict["requestId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
                let request = UserInputRequest(question: question, choices: choices, allowFreeform: allowFreeform, requestId: requestId)
                let response = await userInputHandler(request)
                return .object(["answer": .string(response.answer), "wasFreeform": .bool(response.wasFreeform)])
            }
        }

        let result = try await connection.send(method: "session.create", params: params)

        guard case .object(let dict) = result,
              case .string(let returnedId) = dict["sessionId"] else {
            throw JSONRPCRemoteError(code: -1, message: "No sessionId in session.create response", data: nil)
        }

        let session = CopilotSession(sessionId: returnedId, connection: connection, config: config)
        session.capabilities = SessionCapabilities.from(dict["capabilities"])
        if case .string(let wp) = dict["workspacePath"] { session.workspacePath = wp }

        // Parse relay v2 response fields
        if case .bool(let r) = dict["resumed"] { session.resumed = r }
        if case .string(let pq) = dict["pendingQuestion"] {
            session.pendingQuestion = pq
        } else if case .object(let pqDict) = dict["pendingQuestion"],
                  case .string(let q) = pqDict["question"] {
            session.pendingQuestion = q
        }
        if case .string(let pr) = dict["pendingRequestId"] { session.pendingRequestId = pr }
        if case .string(let snap) = dict["snapshot"] { session.snapshotData = snap }
        if case .int(let ts) = dict["snapshotTimestamp"] { session.snapshotTimestamp = ts }
        if case .string(let ctx) = dict["recoveredContext"] { session.recoveredContext = ctx }

        // Register early event handler if provided
        if let onEvent = config.onEvent {
            await session.on(onEvent)
        }

        return session
    }

    /// Convenience: create session with just a model name (backwards compatible).
    public func createSession(model: String? = nil) async throws -> CopilotSession {
        try await createSession(config: SessionConfig(model: model))
    }

    /// Create an autonomous agent that runs in an infinite loop.
    ///
    /// The agent auto-injects `send_response` and `ask_user` tools and instructs
    /// the model to use them. Call `agent.start(prompt:)` to begin execution.
    ///
    /// ```swift
    /// let agent = try await client.createAgent(config: AgentConfig(
    ///     instructions: "You are a coding assistant.",
    ///     tools: [readFileTool, writeFileTool],
    ///     onResponse: { message in print("Agent: \(message)") },
    ///     onAskUser: { question in
    ///         print("Agent asks: \(question)")
    ///         return readLine()!
    ///     }
    /// ))
    /// try await agent.start(prompt: "Build a REST API")
    /// ```
    public func createAgent(config: AgentConfig) async throws -> CopilotAgent {
        let sessionConfig = CopilotAgent.buildSessionConfig(config: config)
        let session = try await createSession(config: sessionConfig)
        return CopilotAgent(session: session, config: config)
    }

    /// Resume an existing session by its ID.
    public func resumeSession(sessionId: String, config: SessionConfig = SessionConfig()) async throws -> CopilotSession {
        let params = config.buildParams(sessionId: sessionId)

        let permHandler = config.onPermissionRequest
        connection.registerRequestHandler("permission.request") { params in
            if let permHandler, case .object(let dict) = params {
                let request = PermissionRequest(
                    kind: dict["kind"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "unknown",
                    toolCallId: nil, toolName: nil, fileName: nil, fullCommandText: nil,
                    requestId: dict["requestId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "",
                    rawData: params ?? .null
                )
                let result = await permHandler(request)
                return .object(["result": .object(["kind": .string(result.rawValue)])])
            }
            return .object(["result": .object(["kind": .string("approved")])])
        }

        let result = try await connection.send(method: "session.resume", params: params)

        guard case .object(let dict) = result,
              case .string(let returnedId) = dict["sessionId"] else {
            throw JSONRPCRemoteError(code: -1, message: "No sessionId in session.resume response", data: nil)
        }

        let session = CopilotSession(sessionId: returnedId, connection: connection, config: config)
        session.capabilities = SessionCapabilities.from(dict["capabilities"])
        if case .string(let wp) = dict["workspacePath"] { session.workspacePath = wp }

        // Parse relay v2 response fields
        if case .bool(let r) = dict["resumed"] { session.resumed = r }
        if case .string(let pq) = dict["pendingQuestion"] {
            session.pendingQuestion = pq
        } else if case .object(let pqDict) = dict["pendingQuestion"],
                  case .string(let q) = pqDict["question"] {
            session.pendingQuestion = q
        }
        if case .string(let pr) = dict["pendingRequestId"] { session.pendingRequestId = pr }
        if case .string(let snap) = dict["snapshot"] { session.snapshotData = snap }
        if case .int(let ts) = dict["snapshotTimestamp"] { session.snapshotTimestamp = ts }
        if case .string(let ctx) = dict["recoveredContext"] { session.recoveredContext = ctx }

        return session
    }

    /// List all persisted sessions, optionally filtered by repository.
    public func listSessions(repository: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let repository { params["repository"] = .string(repository) }
        return try await connection.send(method: "session.list", params: params)
    }

    /// Delete a persisted session permanently.
    public func deleteSession(_ sessionId: String) async throws {
        _ = try await connection.send(method: "session.delete", params: [
            "sessionId": .string(sessionId),
        ])
    }

    /// Get the foreground session ID (TUI+server mode only).
    public func getForegroundSessionId() async throws -> String? {
        let result = try await connection.send(method: "session.getForeground", params: [:])
        if case .object(let dict) = result, case .string(let id) = dict["sessionId"] {
            return id
        }
        return nil
    }

    /// Set the foreground session (TUI+server mode only).
    public func setForegroundSessionId(_ sessionId: String) async throws {
        _ = try await connection.send(method: "session.setForeground", params: [
            "sessionId": .string(sessionId),
        ])
    }

    /// Subscribe to client lifecycle events.
    public func on(_ eventType: ClientLifecycleEventType, handler: @escaping @Sendable (ClientLifecycleEvent) -> Void) async {
        await clientEventStore.add(eventType, handler)
    }

    /// Subscribe to all client lifecycle events.
    public func on(_ handler: @escaping @Sendable (ClientLifecycleEvent) -> Void) async {
        await clientEventStore.add(nil, handler)
    }

    /// Access notifications stream for session events & updates.
    public var sessionUpdates: AsyncStream<JSONRPCNotification> {
        connection.notifications
    }

    /// Ping the server.
    public func ping(_ message: String = "hello") async throws -> JSONValue {
        try await connection.send(method: "ping", params: ["message": .string(message)])
    }

    /// Stop the client and close the connection gracefully.
    public func stop() {
        state = .stopped
        connection.close()
    }

    /// Force stop the client without graceful cleanup.
    public func forceStop() {
        state = .stopped
        connection.close()
    }

    /// Disconnect from the CLI (alias for stop).
    public func disconnect() {
        stop()
    }
}

// MARK: - Response Collector

private actor ResponseCollector {
    private var _content: String?

    func set(_ text: String) {
        _content = text
    }

    func result() -> String? {
        _content
    }
}

// MARK: - Send Waiter

private actor SendWaiter {
    var content: String?
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed = false

    func setContent(_ text: String) {
        content = text
    }

    func complete() {
        guard !completed else { return }
        completed = true
        continuation?.resume()
        continuation = nil
    }

    func waitForCompletion() async {
        if completed { return }
        await withCheckedContinuation { cont in
            if completed {
                cont.resume()
            } else {
                continuation = cont
            }
        }
    }
}

// MARK: - Event Handler Store

private actor EventHandlerStore {
    private var handlers: [(SessionEventType?, @Sendable (SessionEvent) -> Void)] = []

    func add(_ type: SessionEventType?, _ handler: @escaping @Sendable (SessionEvent) -> Void) {
        handlers.append((type, handler))
    }

    func getAll() -> [(SessionEventType?, @Sendable (SessionEvent) -> Void)] {
        handlers
    }
}

private actor ClientEventHandlerStore {
    private var handlers: [(ClientLifecycleEventType?, @Sendable (ClientLifecycleEvent) -> Void)] = []

    func add(_ type: ClientLifecycleEventType?, _ handler: @escaping @Sendable (ClientLifecycleEvent) -> Void) {
        handlers.append((type, handler))
    }

    func getAll() -> [(ClientLifecycleEventType?, @Sendable (ClientLifecycleEvent) -> Void)] {
        handlers
    }
}

import Foundation
import SwiftUI
import Combine
import CopilotSDK
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Chat Mode

/// The operating mode for the chat — either interactive session or autonomous agent.
public enum ChatMode: Sendable {
    /// Interactive back-and-forth session.
    case session(SessionConfig)
    /// Autonomous agent with `ask_questions` tool (message + questions).
    case agent(AgentConfig)
}

// MARK: - Chat State

/// The chat's current interaction state.
public enum ChatState: Sendable, Equatable {
    /// Not connected yet.
    case disconnected
    /// Connecting to relay.
    case connecting
    /// Idle — waiting for user prompt.
    case idle
    /// Model is processing / tools are running.
    case working
    /// Context is being compacted (conversation compressed).
    case compacting
    /// Model called `ask_user` — waiting for user reply.
    case waitingForUser(question: String)
    /// Model called `ask_questions` — waiting for structured user replies.
    case waitingForQuestions([AskQuestionItem])
    /// An error occurred.
    case error(String)

    /// Whether the state is `waitingForQuestions`.
    var isWaitingForQuestions: Bool {
        if case .waitingForQuestions = self { return true }
        return false
    }
}

// MARK: - Chat View Model

/// Unified view model for both session and agent chat modes.
/// Handles connection, message dispatch, streaming, tool calls, and todo list.
@MainActor
public final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var messages: [ChatMessage] = [] {
        didSet {
            if messages.count > 100 {
                messages.removeFirst(messages.count - 100)
            }
        }
    }
    @Published public var toolCalls: [ToolCallInfo] = []
    @Published public var todoItems: [TodoItem] = []
    @Published public var chatState: ChatState = .disconnected
    @Published public var inputText: String = ""
    @Published public var isListening: Bool = false

    /// URL to present in SFSafariViewController for Stripe checkout.
    @Published public var stripeCheckoutURL: URL?

    // MARK: - Usage Tracking

    /// Client-authoritative usage and balance tracker.
    public let usageTracker: UsageTracker

    // MARK: - Lazy Attachments

    /// Per-session attachment registry. Files are added eagerly (metadata only)
    /// and loaded lazily when the model calls `view`.
    public let attachmentStore = AttachmentStore()

    // MARK: - Plan Store

    /// Shared plan store for create_plan tool and run plan.
    public let planStore = PlanStore()

    // MARK: - Project Scope

    /// Currently selected project name. When set, scopes chat context
    /// to a specific workspace subdirectory.
    @Published public var projectScope: String?

    /// Skip restoring pending questions from UserDefaults on connect.
    /// Set to `true` for background project sessions that shouldn't inherit main session state.
    public var skipPendingRestore: Bool = false

    /// Messages filtered by the current project scope.
    /// When a project is selected, shows only messages tagged with that project (or untagged system messages).
    /// When no project is selected, shows all messages.
    public var filteredMessages: [ChatMessage] {
        guard let scope = projectScope else { return messages }
        return messages.filter { $0.project == nil || $0.project == scope }
    }

    // MARK: - Configuration

    public let inputModes: InputMode
    private let transport: Transport
    private let mode: ChatMode
    /// Filter deciding which notification types to show in chat.
    /// Returns true if the given type (e.g. "usage", "agent_progress", "build") should be displayed.
    public let notificationFilter: (String) -> Bool

    // MARK: - Internal State

    private var client: CopilotClient?
    private var session: CopilotSession?
    private var agent: CopilotAgent?
    private var agentTask: Task<Void, Error>?
    /// Continuation for ask_user — resumed when user replies.
    private var askUserContinuation: CheckedContinuation<String, Never>?
    /// Continuation for ask_questions — resumed when user submits structured replies.
    private var askQuestionsContinuation: CheckedContinuation<JSONValue, Never>?
    @Published public var activeQuestions: [AskQuestionItem] = []
    /// Handles create_project_request delegation from relay (lazy-initialized on first use).
    private var projectTaskHandler: ProjectTaskHandler?
    
    /// Workspace directory on device for reading templates.
    public let workspaceURL: URL?

    /// External file converter — set by the app to delegate conversion to a site adapter (e.g., convertio.co).
    /// Takes (filePath, outputFormat) and returns the path to the converted file or an error string.
    public var fileConverter: (@Sendable (String, String) async throws -> String)?

    /// Logs chat messages to .neo/reports/sessions/ as JSONL.
    private var sessionLogger: ChatSessionLogger?

    /// Diagnostic: whether agent is non-nil (for testing tools).
    public var hasAgentForDiag: Bool { agent != nil }
    /// Diagnostic: whether session is non-nil (for testing tools).
    public var hasSessionForDiag: Bool { session != nil }

    /// Handler for custom JSON-RPC notifications that aren't session.event or relay notifications.
    /// Used by DiscordService to receive discord_message notifications via the shared WS.
    public var onCustomNotification: ((_ method: String, _ params: [String: JSONValue]?) -> Void)?

    /// Callback for channel-forwarded ask_questions in headless sessions.
    /// When set, questions are dispatched through this handler (e.g., to Discord/WeChat)
    /// instead of being auto-answered. The handler receives the question text for display.
    /// The session enters `.waitingForQuestions` and the next `channelSend` resumes the continuation.
    public var onChannelQuestions: ((_ questionText: String) async -> Void)?

    /// Send a raw JSON-RPC request via the session's connection.
    /// Returns the result value. Throws if not connected or on RPC error.
    public func sendRPC(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let session = session ?? agent?.session else {
            throw ChatViewModelError.notConnected
        }
        return try await session.sendRPC(method: method, params: params)
    }

    enum ChatViewModelError: LocalizedError {
        case notConnected
        var errorDescription: String? { "Not connected to relay" }
    }

    /// Clear all session history (JSONL files).
    public func clearSessionHistory() {
        sessionLogger?.clearHistory()
    }

    // MARK: - Init

    /// Create a chat view model.
    /// - Parameters:
    ///   - transport: WebSocket transport to connect to the relay.
    ///   - mode: `.session(config)` or `.agent(config)`.
    ///   - inputModes: Which input modes are available (.text, .speech, .attachment).
    ///   - notificationFilter: Returns true if a notification type should show in chat.
    public init(
        transport: Transport,
        mode: ChatMode,
        inputModes: InputMode = .textAndSpeech,
        usageTracker: UsageTracker = UsageTracker(),
        workspaceURL: URL? = nil,
        notificationFilter: @escaping (String) -> Bool = { _ in true }
    ) {
        self.transport = transport
        self.mode = mode
        self.inputModes = inputModes
        self.usageTracker = usageTracker
        self.workspaceURL = workspaceURL
        self.notificationFilter = notificationFilter

        if let workspaceURL {
            self.sessionLogger = ChatSessionLogger(workspaceURL: workspaceURL)
        }
    }

    deinit {
        agentTask?.cancel()
    }

    /// Send APNs device token to relay for push notifications.
    public func setDeviceToken(_ token: String, apnsEnv: String? = nil, userId: String? = nil) async {
        await client?.setDeviceToken(token, apnsEnv: apnsEnv, userId: userId)
    }

    /// Archive a project's GitHub repo via the relay's GitHub proxy.
    public func archiveRepo(_ repo: String) async {
        nonisolated(unsafe) let handler = getOrCreateProjectTaskHandler()
        await handler.archiveRepo(repo)
    }

    /// Add a push notification as a system message in the chat.
    /// Coding agent notifications (type: "coding_agent") are handled by CodingAgentNotificationHandler.
    @MainActor
    public func addNotification(title: String, body: String, data: [String: Any] = [:]) {
        // Honor literal \n in body text
        let displayBody = body.replacingOccurrences(of: "\\n", with: "\n")

        // Try coding agent handler first
        if let notification = CodingAgentNotificationHandler.parse(title: title, body: displayBody, userInfo: data) {
            CodingAgentNotificationHandler.apply(
                notification,
                addMessage: { msgTitle, msgBody, repo in
                    let text = "**\(msgTitle)**\n\(msgBody)"
                    let blocks: [ChatMessage.ContentBlock] = [.text(text)]
                    let msg = ChatMessage(role: .system, content: blocks, project: repo)
                    self.messages.append(msg)
                    self.sessionLogger?.log(role: "system", text: text, project: repo)
                },
                usageTracker: usageTracker
            )
            return
        }
        
        // Non-coding-agent notifications: build, testflight, etc.
        var blocks: [ChatMessage.ContentBlock] = []
        let text = "**\(title)**\n\(displayBody)"
        blocks.append(.text(text))
        let repo = (data["repo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let msg = ChatMessage(role: .system, content: blocks, project: repo)
        messages.append(msg)
        sessionLogger?.log(role: "system", text: text, project: repo)
    }

    // MARK: - Debug

    /// Diagnostic string exposing private state for automation/testing.
    public var debugInfo: String {
        let m = String(describing: mode)
        let hasAgent = agent != nil
        let agentRunning = agent?.isRunning ?? false
        let hasSession = session != nil
        let hasClient = client != nil
        return "mode=\(m) agent=\(hasAgent) agentRunning=\(agentRunning) session=\(hasSession) client=\(hasClient) chatState=\(chatState)"
    }

    // MARK: - Connection

    /// Connect to the relay and create a session or agent.
    public func connect() async {
        guard chatState == .disconnected || chatState == .error("") || isErrorState else { return }
        chatState = .connecting

        do {
            let client = CopilotClient(transport: transport)
            self.client = client
            try await client.start()

            switch mode {
            case .session(let config):
                try await connectSession(config: config)

            case .agent(var config):
                try await connectAgent(config: &config)
            }
        } catch {
            chatState = .error(error.localizedDescription)
        }
    }

    private var isErrorState: Bool {
        if case .error = chatState { return true }
        return false
    }

    /// Wait until the view model is connected and ready (idle/waitingForQuestions/working),
    /// or until timeout. Returns `true` if ready, `false` on timeout or error.
    public func waitForReady(timeout: TimeInterval = 15) async -> Bool {
        if isReady { return true }
        return await withCheckedContinuation { continuation in
            var resumed = false
            var cancellable: AnyCancellable?
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !resumed else { return }
                resumed = true
                cancellable?.cancel()
                continuation.resume(returning: false)
            }
            cancellable = $chatState
                .dropFirst() // skip current value
                .sink { state in
                    guard !resumed else { return }
                    switch state {
                    case .disconnected, .connecting, .compacting:
                        return // keep waiting
                    case .error:
                        resumed = true
                        timeoutTask.cancel()
                        cancellable?.cancel()
                        continuation.resume(returning: false)
                    default:
                        resumed = true
                        timeoutTask.cancel()
                        cancellable?.cancel()
                        continuation.resume(returning: true)
                    }
                }
        }
    }

    private var isReady: Bool {
        switch chatState {
        case .idle, .working, .waitingForQuestions, .waitingForUser:
            return true
        default:
            return false
        }
    }

    /// Disconnect and clean up.
    public func disconnect() {
        agentTask?.cancel()
        agentTask = nil
        agent?.stop()
        agent = nil
        session = nil
        client = nil
        chatState = .disconnected
    }

    // MARK: - Session Mode

    private func connectSession(config: SessionConfig) async throws {
        guard let client else { return }

        // Inject manage_todo_list and view tools
        var config = config
        config.tools = (config.tools ?? []) + [makeTodoTool(), makeViewTool(), makeConvertToMarkdownTool(), makeCreatePlanTool(), makeStripeCheckoutTool(), makeStartCodingTaskTool()]

        let session = try await client.createSession(config: config)
        self.session = session

        // Subscribe to events
        await subscribeToEvents(session: session)

        // Handle relay server notifications (usage, progress, build status, delegation)
        session.onRelayNotification = { [weak self] type, params in
            self?.handleRelayNotification(type: type, params: params)
        }

        // Forward custom notifications (e.g., discord_message)
        session.onCustomNotification = { [weak self] method, params in
            self?.onCustomNotification?(method, params)
        }

        usageTracker.resetSession()
        loadChatHistory()
        chatState = .idle
    }

    // MARK: - Agent Mode

    private func connectAgent(config: inout AgentConfig) async throws {
        guard let client else { return }

        // Inject manage_todo_list and view tools
        config.tools.append(makeTodoTool())
        config.tools.append(makeViewTool())
        config.tools.append(makeConvertToMarkdownTool())
        config.tools.append(makeCreatePlanTool())
        config.tools.append(makeStripeCheckoutTool())
        config.tools.append(makeStartCodingTaskTool())

        // Wrap onResponse to update UI
        let originalOnResponse = config.onResponse
        config.onResponse = { [weak self] message in
            await self?.handleAgentResponse(message)
            await originalOnResponse(message)
        }

        // Wrap onAskUser to update UI and wait for user input
        let originalOnAskUser = config.onAskUser
        _ = originalOnAskUser
        config.onAskUser = { [weak self] question in
            guard let self else { return "" }
            return await self.handleAgentAskUser(question)
        }

        let originalOnAskQuestions = config.onAskQuestions
        _ = originalOnAskQuestions
        config.onAskQuestions = { [weak self] payload in
            guard let self else { return .object([:]) }
            let answer = await self.handleAgentAskQuestions(payload)
            return answer
        }

        let agent = try await client.createAgent(config: config)
        self.agent = agent

        // Subscribe to events on the underlying session
        await subscribeToEvents(session: agent.session)

        // Handle relay server notifications (usage, progress, build status, delegation)
        agent.session.onRelayNotification = { [weak self] type, params in
            self?.handleRelayNotification(type: type, params: params)
        }

        // Forward custom notifications (e.g., discord_message)
        agent.session.onCustomNotification = { [weak self] method, params in
            self?.onCustomNotification?(method, params)
        }

        loadChatHistory()
        chatState = .idle

        // Restore pending questions from previous session (if app restarted while waiting)
        restorePendingQuestions()
    }

    // MARK: - Relay Notification Handling

    private func handleRelayNotification(type: String, params: [String: JSONValue]) {
        NSLog("[ChatViewModel] handleRelayNotification: type=%@", type)

        // Generic notification display
        guard notificationFilter(type) else { return }
        let title: String
        if case .string(let t) = params["title"] { title = t } else { title = type }
        let body: String
        if case .string(let b) = params["body"] { body = b } else { body = "" }

        // Convert JSONValue params to [String: Any] for addNotification
        var data: [String: Any] = ["type": type]
        for (key, value) in params {
            switch value {
            case .string(let s): data[key] = s
            case .int(let n): data[key] = n
            case .double(let n): data[key] = n
            case .bool(let b): data[key] = b
            default: break
            }
        }

        Task { @MainActor in
            self.addNotification(title: title, body: body, data: data)
        }
    }

    private func getOrCreateProjectTaskHandler() -> ProjectTaskHandler {
        if let handler = projectTaskHandler { return handler }

        // Derive HTTP proxy URL from the transport
        let proxyURL: URL
        if let wsTransport = transport as? WebSocketTransport {
            proxyURL = ProjectTaskHandler.httpURL(from: wsTransport.url)
        } else {
            proxyURL = URL(string: "http://localhost:8766")!
        }

        let client = self.client
        let handler = ProjectTaskHandler(
            proxyBaseURL: proxyURL,
            workspaceURL: workspaceURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
            sendNotification: { [weak client] method, params in
                await client?.sendNotification(method: method, params: params)
            }
        )
        projectTaskHandler = handler
        return handler
    }

    // MARK: - Chat History

    private func loadChatHistory() {
        guard messages.isEmpty else { return }
        guard let logger = sessionLogger else { return }
        let history = logger.loadHistory()
        guard !history.isEmpty else { return }

        let restored = history.map { entry in
            let role: ChatMessage.Role = switch entry.role {
            case "assistant": .assistant
            case "system": .system
            default: .user
            }
            // Honor literal \n in system notification text
            let text = (entry.role == "system") ? entry.text.replacingOccurrences(of: "\\n", with: "\n") : entry.text
            return ChatMessage(
                role: role,
                content: entry.role == "assistant" ? parseContentBlocks(text) : [.text(text)],
                timestamp: entry.timestamp,
                project: entry.project
            )
        }
        messages.insert(contentsOf: restored, at: 0)
    }

    // MARK: - Event Subscription

    private func subscribeToEvents(session: CopilotSession) async {
        // Delta streaming — accumulate into the current assistant message
        await session.on(.assistantMessageDelta) { [weak self] event in
            guard let self else { return }
            if case .object(let data) = event.data,
               case .string(let delta) = data["delta"] {
                Task { @MainActor in
                    self.appendOrUpdateAssistantDelta(delta)
                }
            }
        }

        // Full assistant message (non-streaming or final)
        await session.on(.assistantMessage) { [weak self] event in
            guard let self else { return }
            if case .object(let data) = event.data,
               case .string(let content) = data["content"] {
                Task { @MainActor in
                    self.finalizeAssistantMessage(content)
                }
            }
        }

        await session.on(.assistantTurnStart) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.chatState = .working
            }
        }

        await session.on(.sessionIdle) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Only go idle if not waiting for user (ask_user sets its own state)
                if case .waitingForUser = self.chatState { return }
                if case .waitingForQuestions = self.chatState { return }
                self.chatState = .idle
            }
        }

        // Context compaction tracking
        await session.on(.sessionCompactionStart) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.chatState = .compacting
            }
        }

        await session.on(.sessionCompactionComplete) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if case .compacting = self.chatState {
                    self.chatState = .working
                }
            }
        }

        // Tool execution tracking
        await session.on(.toolExecutionStart) { [weak self] event in
            guard let self else { return }
            if case .object(let data) = event.data {
                let toolName = data["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "unknown"
                let toolCallId = data["toolCallId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? UUID().uuidString
                let args = data["arguments"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
                Task { @MainActor in
                    self.toolCalls.append(ToolCallInfo(id: toolCallId, name: toolName, arguments: args))
                    // Keep only the latest 5 tool calls visible in chat
                    if self.toolCalls.count > 5 {
                        self.toolCalls.removeFirst(self.toolCalls.count - 5)
                    }
                }
            }
        }

        await session.on(.toolExecutionComplete) { [weak self] event in
            guard let self else { return }
            if case .object(let data) = event.data {
                let toolCallId = data["toolCallId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
                let result = data["result"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
                Task { @MainActor in
                    if let toolCallId, let idx = self.toolCalls.firstIndex(where: { $0.id == toolCallId }) {
                        self.toolCalls[idx].status = .completed
                        self.toolCalls[idx].result = result
                        let name = self.toolCalls[idx].name
                        let args = self.toolCalls[idx].arguments ?? ""
                        let truncated = String((result ?? "").prefix(500))
                        var parts = "[\(name)]"
                        if !args.isEmpty { parts += " \(args)" }
                        if !truncated.isEmpty { parts += "\n\(truncated)" }
                        self.sessionLogger?.log(role: "tool_result", text: parts, project: self.projectScope)
                    }
                }
            }
        }

        // Session errors
        await session.on(.sessionError) { [weak self] event in
            guard let self else { return }
            if case .object(let data) = event.data,
               case .string(let message) = data["message"] {
                Task { @MainActor in
                    self.chatState = .error(message)
                }
            }
        }

        // Usage tracking — record token consumption and cost (server-calculated)
        await session.on(.assistantUsage) { [weak self] event in
            guard let self else { return }
            if case .object(let data) = event.data,
               let cost = data["cost"]?.doubleValue {
                let model = data["model"]?.stringValue ?? "unknown"
                let promptTokens = data["inputTokens"]?.intValue ?? data["prompt_tokens"]?.intValue ?? 0
                let completionTokens = data["outputTokens"]?.intValue ?? data["completion_tokens"]?.intValue ?? 0
                Task { @MainActor in
                    self.usageTracker.record(
                        model: model,
                        promptTokens: promptTokens,
                        completionTokens: completionTokens,
                        cost: cost
                    )
                }
            }
        }

        // Stripe credits are handled client-side via SFSafariViewController + relay /stripe/verify
        // (see NeoxApp.onOpenURL → verifyStripeSession → usageTracker.addCredits)
    }

    // MARK: - Run Plan

    /// Execute a plan by sending its prompt through the chat pipeline.
    /// Logs execution start/completion in the PlanStore.
    public func runPlan(_ plan: Plan) async {
        var execution = PlanExecution(planId: plan.id)
        planStore.addExecution(execution)

        // Inject a system-like message indicating plan execution
        let header = ChatMessage(
            role: .user,
            content: [.text("[Plan: \(plan.name)]\n\(plan.prompt)")],
            project: projectScope
        )
        messages.append(header)
        let messageCountBefore = messages.count

        // Use normal send flow
        chatState = .working
        await sendPrompt(plan.prompt)

        // Wait briefly for the agent to process and produce output
        try? await Task.sleep(for: .seconds(1))

        // Capture assistant response — gather all assistant messages added after our header
        let newMessages = messages.suffix(from: messageCountBefore)
        let resultText = newMessages
            .filter { $0.role == .assistant }
            .map { $0.fullText }
            .joined(separator: "\n\n")

        // Mark execution completed
        execution.complete(
            result: resultText.isEmpty ? "Completed (no output)" : resultText,
            tokensUsed: nil,
            cost: nil
        )
        planStore.addExecution(execution)
    }

    // MARK: - Send Message

    /// Send a message. Handles three cases:
    /// 1. Normal prompt — user sends a new message
    /// 2. ask_user reply — resumes the waiting continuation
    /// 3. Steer — injects immediate message during tool execution
    public func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // Handle slash commands
        if text.hasPrefix("/") {
            handleSlashCommand(text)
            return
        }

        // Prepend attachment context if files are attached
        let attachmentDesc = attachmentStore.promptDescription()
        let promptText: String
        if let desc = attachmentDesc {
            promptText = "\(desc)\n\n\(text)"
        } else {
            promptText = text
        }

        // Add user message to the chat (show original text, not the injection)
        let userMessage = ChatMessage(
            role: .user,
            content: [.text(text)],
            project: projectScope
        )
        messages.append(userMessage)
        sessionLogger?.log(role: "user", text: text, project: projectScope)

        // Clear attachments after sending
        if attachmentDesc != nil {
            attachmentStore.clear()
        }

        switch chatState {
        case .waitingForUser:
            // Resume ask_user continuation
            askUserContinuation?.resume(returning: promptText)
            askUserContinuation = nil
            chatState = .working

        case .waitingForQuestions(let questions):
            guard let first = questions.first else { return }
            submitAskQuestions([
                first.header: AskQuestionAnswer(selected: [], freeText: promptText, skipped: false)
            ])

        case .working:
            // Steer — inject immediate message
            do {
                try await session?.steer(prompt: promptText)
            } catch {
                appendSystemMessage("Steer failed: \(error.localizedDescription)")
                chatState = .idle
            }

        case .idle:
            // Normal prompt
            chatState = .working
            await sendPrompt(promptText)

        default:
            break
        }
    }

    // MARK: - Slash Commands

    private func handleSlashCommand(_ text: String) {
        let parts = text.split(separator: " ", maxSplits: 1)
        let command = String(parts[0]).lowercased()

        switch command {
        case "/clear":
            messages.removeAll()
            sessionLogger?.log(role: "clear", text: "Messages cleared.", project: projectScope)
            appendSystemMessage("Messages cleared.")
        default:
            appendSystemMessage("Unknown command: \(command)\nAvailable: /clear")
        }
    }

    /// Send a message with explicit text (bypasses inputText property).
    /// Used by automation (AppAgent) to avoid race conditions with UI bindings.
    /// When startAgent is true, starts the agent loop directly (avoids Task scheduling issues).
    public func send(_ text: String, startAgent: Bool = false, source: String? = nil) async {
        inputText = text
        if startAgent {
            // Direct agent start — bypasses the fire-and-forget Task in sendPrompt()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            inputText = ""
            messages.append(ChatMessage(role: .user, content: [.text(trimmed)], project: projectScope, source: source))
            chatState = .working
            if let agent {
                if !agent.isRunning {
                    // Start agent loop in background Task — agent.start() blocks until loop ends
                    agentTask = Task { [weak self] in
                        do {
                            try await agent.start(prompt: trimmed)
                        } catch {
                            await MainActor.run {
                                self?.appendSystemMessage("Agent error: \(error.localizedDescription)")
                                self?.chatState = .error(error.localizedDescription)
                            }
                        }
                    }
                } else {
                    // Agent already running — steer its session with the new prompt
                    do {
                        _ = try await agent.session.steer(prompt: trimmed)
                    } catch {
                        appendSystemMessage("Steer failed: \(error.localizedDescription)")
                    }
                }
            } else if let session {
                do {
                    try await session.steer(prompt: trimmed)
                } catch {
                    appendSystemMessage("Steer failed: \(error.localizedDescription)")
                }
            }
        } else {
            await send()
        }
    }

    /// Send a hidden message that the model receives but the user doesn't see.
    /// Used for system-triggered prompts like onboarding.
    public func sendHidden(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chatState = .working
        await sendPrompt(trimmed)
    }

    /// Add a message to the displayed list without triggering agent processing.
    /// Used to mirror project-session messages into the main chat view.
    @MainActor
    public func mirror(_ message: ChatMessage) {
        messages.append(message)
    }

    /// State-aware send for channel messages (Discord, WeChat).
    /// Routes to the correct method based on current chat state:
    /// - idle → start agent (new turn)
    /// - waitingForQuestions / waitingForUser → answer/resume (answer-question)
    /// - working → steer running agent
    public func channelSend(_ text: String, source: String? = nil) async {
        switch chatState {
        case .waitingForQuestions, .waitingForUser:
            _ = await sendToRelay(text, source: source)
        case .working:
            await send(text, startAgent: false, source: source)
        default:
            await send(text, startAgent: true, source: source)
        }
    }

    /// Send a prompt directly to the relay via the underlying session WebSocket.
    /// Used by automation — sends the message and waits for session idle/on-hold.
    /// Returns the last assistant message content for diagnostics.
    public func sendToRelay(_ text: String, source: String? = nil) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        
        let beforeCount = messages.count
        messages.append(ChatMessage(role: .user, content: [.text(trimmed)], project: projectScope, source: source))

        // In loop mode, the model may be blocked waiting for ask_questions or ask_user response.
        // Answer the pending question with the user's text to unblock the model,
        // rather than sending a new session.send (which would deadlock).
        let needsSend: Bool
        switch chatState {
        case .waitingForQuestions(let questions):
            guard let first = questions.first else {
                needsSend = true
                break
            }
            submitAskQuestions([
                first.header: AskQuestionAnswer(selected: [], freeText: trimmed, skipped: false)
            ])
            needsSend = false
        case .waitingForUser:
            askUserContinuation?.resume(returning: trimmed)
            askUserContinuation = nil
            chatState = .working
            needsSend = false
        default:
            needsSend = true
        }

        if needsSend {
            chatState = .working

            // Use the agent's session if in agent mode, otherwise the direct session
            let targetSession = agent?.session ?? session
            guard let targetSession else {
                chatState = .idle
                return "no-session"
            }
            
            do {
                _ = try await targetSession.send(prompt: trimmed)
            } catch {
                let msg = error.localizedDescription
                appendSystemMessage("Error: \(msg)")
                chatState = .idle
                return "error: \(msg)"
            }
        }

        // Wait for chatState to leave .working (idle, waitingForUser, error, etc.)
        // 180s timeout for operations that involve tool calls (start_coding_task, etc.)
        var stateObserver: AnyCancellable?
        let stateStream = AsyncStream<ChatState> { continuation in
            stateObserver = self.$chatState.sink { state in
                continuation.yield(state)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in stateStream {
                    if case .working = state { continue }
                    break
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(180))
            }
            await group.next()
            group.cancelAll()
        }
        stateObserver?.cancel()

        // Safety: if still stuck in .working after timeout, force reset
        if case .working = chatState {
            appendSystemMessage("Response timed out after 180s. Try again or start a new chat.")
            chatState = .idle
        }

        // Collect new assistant messages
        let newMessages = messages.suffix(from: beforeCount + 1)
            .filter { $0.role == .assistant }
            .map { $0.fullText }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return newMessages.isEmpty ? "sent-no-reply" : newMessages
    }

    /// Send a message with an image attachment.
    public func sendWithImage(_ imageData: Data, mimeType: String, text: String) async {
        guard let session else { return }

        // Add user message
        var blocks: [ChatMessage.ContentBlock] = [.image(imageData, mimeType: mimeType)]
        if !text.isEmpty {
            blocks.insert(.text(text), at: 0)
        }
        messages.append(ChatMessage(role: .user, content: blocks, project: projectScope))

        chatState = .working
        let base64 = imageData.base64EncodedString()
        do {
            try await session.sendWithImage(base64, mimeType: mimeType, text: text)
        } catch {
            appendSystemMessage("Send failed: \(error.localizedDescription)")
            chatState = .idle
        }
    }

    // MARK: - Private Send Helpers

    private func sendPrompt(_ text: String) async {
        // Inject project context if a project is scoped
        let effectiveText: String
        if let project = projectScope {
            effectiveText = "[Project: \(project)] \(text)"
        } else {
            effectiveText = text
        }

        switch mode {
        case .session:
            do {
                try await session?.send(prompt: effectiveText)
            } catch {
                appendSystemMessage("Send failed: \(error.localizedDescription)")
                chatState = .idle
            }

        case .agent:
            if let agent, !agent.isRunning {
                // Start agent loop with the initial prompt
                agentTask = Task {
                    do {
                        try await agent.start(prompt: effectiveText)
                    } catch {
                        await MainActor.run {
                            self.appendSystemMessage("Agent error: \(error.localizedDescription)")
                            self.chatState = .error(error.localizedDescription)
                        }
                    }
                }
            } else {
                // Agent is already running — this is a follow-up / steer
                do {
                    try await session?.steer(prompt: effectiveText)
                } catch {
                    appendSystemMessage("Steer failed: \(error.localizedDescription)")
                    chatState = .idle
                }
            }
        }
    }

    // MARK: - Agent Callbacks

    private func handleAgentResponse(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Deduplicate: if the last assistant message already has this content
        // (delivered via streaming), don't add it again.
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant {
            let existing = messages[lastIndex].fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing == trimmed {
                messages[lastIndex].isStreaming = false
                return
            }
        }

        // ask_questions message delivers a response — add as assistant message
        let blocks = parseContentBlocks(trimmed)
        let msg = ChatMessage(role: .assistant, content: blocks, project: projectScope)
        messages.append(msg)
    }

    private func handleAgentAskUser(_ question: String) async -> String {
        // Update state on main thread, then wait for user to reply
        chatState = .waitingForUser(question: question)

        // Add the question as an assistant message
        let blocks = parseContentBlocks(question)
        messages.append(ChatMessage(role: .assistant, content: blocks, project: projectScope))

        // Wait for user reply via continuation
        return await withCheckedContinuation { continuation in
            self.askUserContinuation = continuation
        }
    }

    private func handleAgentAskQuestions(_ payload: JSONValue) async -> JSONValue {
        // Note: the 'message' field is already displayed by onResponse callback in Client.buildTools()
        // — no need to add it again here.

        let questions = parseAskQuestions(payload)
        guard !questions.isEmpty else {
            return .object([:])
        }

        // Headless/background sessions with channel forwarding:
        // If onChannelQuestions is set, forward questions to the channel (Discord/WeChat)
        // and wait for the next channelSend to resume the continuation.
        if skipPendingRestore, let onChannelQuestions {
            // Build a text representation of the questions for the channel
            let questionText: String
            if questions.count == 1 {
                questionText = questions[0].question
            } else {
                questionText = questions.enumerated().map { i, q in "\(i + 1). \(q.question)" }.joined(separator: "\n")
            }

            chatState = .waitingForQuestions(questions)
            activeQuestions = questions

            // Dispatch to channel (Discord/WeChat) — non-blocking
            await onChannelQuestions(questionText)

            // Wait for answer via continuation (channelSend will call submitAskQuestions)
            return await withCheckedContinuation { continuation in
                self.askQuestionsContinuation = continuation
            }
        }

        // Headless/background sessions without channel forwarding: auto-answer.
        if skipPendingRestore {
            return .object([
                "answer": .string("Acknowledged. No follow-up needed right now.")
            ])
        }

        // Single freeform question with no options: merge question into assistant bubble
        if questions.count == 1, questions[0].options.isEmpty {
            let questionText = questions[0].question
            if let lastIndex = messages.lastIndex(where: { $0.role == .assistant }),
               case .text(let existingText) = messages[lastIndex].content.last {
                // Append question to existing assistant message
                var content = messages[lastIndex].content
                content[content.count - 1] = .text(existingText + "\n\n" + questionText)
                messages[lastIndex] = ChatMessage(
                    id: messages[lastIndex].id,
                    role: .assistant,
                    content: content,
                    project: messages[lastIndex].project
                )
            }
        }

        chatState = .waitingForQuestions(questions)
        activeQuestions = questions

        // Persist questions + requestId for recovery after app restart
        persistPendingQuestions(questions)

        return await withCheckedContinuation { continuation in
            self.askQuestionsContinuation = continuation
        }
    }

    public func submitAskQuestions(_ answers: [String: AskQuestionAnswer]) {
        var result: [String: JSONValue] = [:]
        for (header, answer) in answers {
            result[header] = .object([
                "selected": .array(answer.selected.map(JSONValue.string)),
                "freeText": answer.freeText.map(JSONValue.string) ?? .null,
                "skipped": .bool(answer.skipped),
            ])
        }

        // Add Q&A summary to chat history (skip for single freeform — already shown as user message)
        let isSingleFreeform = activeQuestions.count == 1 && activeQuestions[0].options.isEmpty
        if !isSingleFreeform {
            let summary = formatQASummary(questions: activeQuestions, answers: answers)
            messages.append(ChatMessage(role: .user, content: [.text(summary)], project: projectScope))
        }

        if let continuation = askQuestionsContinuation {
            // Normal path: continuation exists, resume it
            continuation.resume(returning: .object(result))
            askQuestionsContinuation = nil
        } else if let requestId = UserDefaults.standard.string(forKey: "pendingAskQuestionsRequestId") {
            // Recovery path: app restarted, send result directly to relay
            let jsonResult = JSONValue.object(result)
            if let data = try? JSONEncoder().encode(jsonResult), let text = String(data: data, encoding: .utf8) {
                Task {
                    await agent?.sendPendingToolResult(requestId: requestId, result: "User answered: \(text)")
                }
            }
        }

        activeQuestions = []
        chatState = .working
        clearPendingQuestions()
    }

    private func formatQASummary(questions: [AskQuestionItem], answers: [String: AskQuestionAnswer]) -> String {
        var lines: [String] = []
        for q in questions {
            guard let answer = answers[q.header] else { continue }
            if answer.skipped { continue }
            lines.append("**\(q.question)**")
            if !answer.selected.isEmpty {
                lines.append(answer.selected.joined(separator: ", "))
            }
            if let text = answer.freeText, !text.isEmpty {
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n")
    }

    public func skipAskQuestions() {
        var skipped: [String: AskQuestionAnswer] = [:]
        for question in activeQuestions {
            skipped[question.header] = AskQuestionAnswer(selected: [], freeText: nil, skipped: true)
        }
        submitAskQuestions(skipped)
    }

    // MARK: - Pending Questions Persistence

    private func persistPendingQuestions(_ questions: [AskQuestionItem]) {
        if let data = try? JSONEncoder().encode(questions) {
            UserDefaults.standard.set(data, forKey: "pendingAskQuestions")
        }
        if let requestId = agent?.session.pendingRequestId {
            UserDefaults.standard.set(requestId, forKey: "pendingAskQuestionsRequestId")
        }
    }

    private func clearPendingQuestions() {
        UserDefaults.standard.removeObject(forKey: "pendingAskQuestions")
        UserDefaults.standard.removeObject(forKey: "pendingAskQuestionsRequestId")
    }

    /// Restore pending questions from previous session (after app restart).
    /// Call after agent connects but before user interaction.
    func restorePendingQuestions() {
        guard !skipPendingRestore else { return }
        guard let data = UserDefaults.standard.data(forKey: "pendingAskQuestions"),
              let questions = try? JSONDecoder().decode([AskQuestionItem].self, from: data),
              !questions.isEmpty else { return }

        NSLog("[ChatVM] Restoring %d pending questions from previous session", questions.count)
        activeQuestions = questions
        chatState = .waitingForQuestions(questions)
    }

    private func parseAskQuestions(_ payload: JSONValue) -> [AskQuestionItem] {
        guard case .object(let root) = payload,
              case .array(let rawQuestions) = root["questions"] else {
            return []
        }

        return rawQuestions.enumerated().compactMap { index, entry in
            guard case .object(let q) = entry else { return nil }

            let header: String
            if case .string(let h) = q["header"], !h.isEmpty {
                header = h
            } else {
                header = "Question \(index + 1)"
            }

            guard case .string(let questionText) = q["question"], !questionText.isEmpty else {
                return nil
            }

            let multiSelect: Bool
            if case .bool(let b) = q["multiSelect"] {
                multiSelect = b
            } else {
                multiSelect = false
            }

            let allowFreeformInput: Bool
            if case .bool(let b) = q["allowFreeformInput"] {
                allowFreeformInput = b
            } else {
                allowFreeformInput = false
            }

            let options: [AskQuestionOption]
            if case .array(let rawOptions) = q["options"] {
                options = rawOptions.compactMap { opt in
                    guard case .object(let o) = opt,
                          case .string(let label) = o["label"],
                          !label.isEmpty else {
                        return nil
                    }

                    let description: String?
                    if case .string(let d) = o["description"], !d.isEmpty {
                        description = d
                    } else {
                        description = nil
                    }

                    let recommended: Bool
                    if case .bool(let r) = o["recommended"] {
                        recommended = r
                    } else {
                        recommended = false
                    }

                    return AskQuestionOption(label: label, description: description, recommended: recommended)
                }
            } else {
                options = []
            }

            return AskQuestionItem(
                header: header,
                question: questionText,
                multiSelect: multiSelect,
                options: options,
                allowFreeformInput: allowFreeformInput
            )
        }
    }

    // MARK: - Message Accumulation

    /// Append a delta token to the current streaming assistant message,
    /// or create a new one if none exists.
    private func appendOrUpdateAssistantDelta(_ delta: String) {
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty else { return }

        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].isStreaming {
            // Append to existing streaming message
            let existing = messages[lastIndex].fullText
            let updated = existing + delta
            messages[lastIndex].content = parseContentBlocks(updated)
        } else {
            // Start a new streaming message
            let blocks = parseContentBlocks(delta)
            messages.append(ChatMessage(role: .assistant, content: blocks, isStreaming: true, project: projectScope))
        }
    }

    /// Finalize a streaming message or add a complete assistant message.
    private func finalizeAssistantMessage(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].isStreaming {
            if trimmed.isEmpty {
                if messages[lastIndex].fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.remove(at: lastIndex)
                } else {
                    messages[lastIndex].isStreaming = false
                    sessionLogger?.log(role: "assistant", text: messages[lastIndex].fullText, project: projectScope)
                }
            } else {
                messages[lastIndex].content = parseContentBlocks(trimmed)
                messages[lastIndex].isStreaming = false
                sessionLogger?.log(role: "assistant", text: trimmed, project: projectScope)
            }
        } else {
            guard !trimmed.isEmpty else { return }

            // Deduplicate: if last assistant message has same content, skip
            if let lastIndex = messages.indices.last,
               messages[lastIndex].role == .assistant,
               messages[lastIndex].fullText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                return
            }

            let blocks = parseContentBlocks(trimmed)
            messages.append(ChatMessage(role: .assistant, content: blocks, project: projectScope))
            sessionLogger?.log(role: "assistant", text: trimmed, project: projectScope)
        }
    }

    /// Add a system message (for errors, status updates).
    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: [.text(text)], project: projectScope))
    }

    // MARK: - Todo Tool

    /// Build the `manage_todo_list` tool definition.
    private func makeTodoTool() -> ToolDefinition {
        ToolDefinition(
            name: "manage_todo_list",
            description: "Manage a todo list to track tasks. Pass the complete array of todo items.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "todoList": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "id": .object(["type": .string("number")]),
                                "title": .object(["type": .string("string")]),
                                "status": .object([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string("not-started"),
                                        .string("in-progress"),
                                        .string("completed"),
                                    ]),
                                ]),
                            ]),
                            "required": .array([.string("id"), .string("title"), .string("status")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("todoList")]),
            ]),
            skipPermission: true,
            handler: { [weak self] args in
                await self?.handleTodoUpdate(args)
                return "Todo list updated."
            }
        )
    }

    /// Parse the tool arguments and update the todo list.
    private func handleTodoUpdate(_ args: JSONValue) {
        guard case .object(let dict) = args,
              case .array(let items) = dict["todoList"] else { return }

        var newTodos: [TodoItem] = []
        for item in items {
            guard case .object(let itemDict) = item else { continue }
            let id: Int
            if case .int(let n) = itemDict["id"] { id = n }
            else if case .double(let d) = itemDict["id"] { id = Int(d) }
            else { continue }

            guard case .string(let title) = itemDict["title"],
                  case .string(let statusStr) = itemDict["status"],
                  let status = TodoItem.Status(rawValue: statusStr) else { continue }

            newTodos.append(TodoItem(id: id, title: title, status: status))
        }
        todoItems = newTodos
    }

    // MARK: - Create Plan Tool

    /// Build the `create_plan` tool definition.
    /// Allows the agent to create a plan from chat.
    private func makeCreatePlanTool() -> ToolDefinition {
        ToolDefinition(
            name: "create_plan",
            description: "Create a scheduled plan. Plans can run prompts on a schedule or manually.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Short name for the plan"),
                    ]),
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("The prompt/instructions to execute when the plan runs"),
                    ]),
                    "schedule": .object([
                        "type": .string("string"),
                        "description": .string("Schedule type: 'manual', 'daily', 'hourly', or interval in minutes like '30m'"),
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Model to use. Default: gpt-4.1"),
                    ]),
                ]),
                "required": .array([.string("name"), .string("prompt")]),
            ]),
            skipPermission: true,
            handler: { [weak self] args in
                guard let self else { return "Error: view model deallocated" }
                return await self.handleCreatePlan(args)
            }
        )
    }

    /// Handle `create_plan` tool call.
    private func handleCreatePlan(_ args: JSONValue) -> String {
        guard case .object(let dict) = args,
              case .string(let name) = dict["name"],
              case .string(let prompt) = dict["prompt"] else {
            return "Error: missing required 'name' and 'prompt' parameters"
        }

        let model: String
        if case .string(let m) = dict["model"] {
            model = m
        } else {
            model = "gpt-4.1"
        }

        let schedule: PlanSchedule
        if case .string(let s) = dict["schedule"] {
            switch s.lowercased() {
            case "daily":
                schedule = .interval(seconds: 86400)
            case "hourly":
                schedule = .interval(seconds: 3600)
            case "manual", "":
                schedule = .manual
            default:
                // Parse "30m", "2h", etc.
                if s.hasSuffix("m"), let mins = Int(s.dropLast()) {
                    schedule = .interval(seconds: mins * 60)
                } else if s.hasSuffix("h"), let hrs = Int(s.dropLast()) {
                    schedule = .interval(seconds: hrs * 3600)
                } else {
                    schedule = .manual
                }
            }
        } else {
            schedule = .manual
        }

        let plan = Plan(
            name: name,
            prompt: prompt,
            schedule: schedule,
            model: model
        )
        planStore.createPlan(plan)

        let scheduleDesc: String
        switch schedule {
        case .manual: scheduleDesc = "manual"
        case .interval(let s): scheduleDesc = "every \(s / 60) minutes"
        case .once(let d): scheduleDesc = "once at \(d)"
        case .cron(let e, _): scheduleDesc = "cron: \(e)"
        }

        return "Plan '\(name)' created (\(scheduleDesc), model: \(model)). ID: \(plan.id)"
    }

    // MARK: - Get Attachment Tool

    // MARK: - Stripe Checkout Tool

    /// Build the `stripe_checkout` tool definition.
    /// Agent-only payment helper: returns an external Stripe checkout link.
    private func makeStripeCheckoutTool() -> ToolDefinition {
        ToolDefinition(
            name: "stripe_checkout",
            description: "Generate an external Stripe checkout link. Use only when user explicitly asks for Stripe payment or when credits are low. Keep Apple IAP as default for in-app digital credits.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "amount_usd": .object([
                        "type": .string("number"),
                        "description": .string("Optional requested top-up amount in USD"),
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Why Stripe is needed (e.g. user asked for Stripe, credits exhausted)"),
                    ]),
                ]),
            ]),
            skipPermission: true,
            handler: { [weak self] args in
                guard let self else { return "Error: view model deallocated" }
                return await self.handleStripeCheckout(args)
            }
        )
    }

    /// Handle `stripe_checkout` tool call.
    private func handleStripeCheckout(_ args: JSONValue) async -> String {
        // Payment link URL — set via UserDefaults or fall back to test link
        let base = (UserDefaults.standard.string(forKey: "stripePaymentLink")
            ?? "https://buy.stripe.com/test_14A7sLfQc0DY3YTfGp24004")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            return "Stripe checkout is not configured."
        }

        var requestedAmount: Double?
        var reason = ""
        if case .object(let dict) = args {
            if case .double(let d) = dict["amount_usd"] { requestedAmount = d }
            else if case .int(let i) = dict["amount_usd"] { requestedAmount = Double(i) }
            if case .string(let r) = dict["reason"] { reason = r }
        }

        let explicitStripeIntent = reason.lowercased().contains("stripe") || reason.lowercased().contains("checkout") || reason.lowercased().contains("payment")
        if !usageTracker.isLowBalance && !usageTracker.hasInsufficientBalance && !explicitStripeIntent {
            return "Balance is still sufficient ($\(String(format: "%.2f", usageTracker.balance))). Keep Apple IAP as default unless user explicitly requests Stripe."
        }

        var checkoutURL = base
        if var components = URLComponents(string: base) {
            var query = components.queryItems ?? []
            // client_reference_id flows through to checkout.session.completed
            let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            UserDefaults.standard.set(deviceId, forKey: "pendingStripeCheckoutRef")
            query.append(URLQueryItem(name: "client_reference_id", value: deviceId))
            if let requestedAmount, requestedAmount > 0 {
                query.append(URLQueryItem(name: "amount_usd", value: String(format: "%.2f", requestedAmount)))
            }
            components.queryItems = query
            checkoutURL = components.url?.absoluteString ?? base
        }

        // Open payment link — try SFSafariViewController via notification, fallback to external Safari
        if let url = URL(string: checkoutURL) {
            await MainActor.run {
                self.stripeCheckoutURL = url
                NotificationCenter.default.post(
                    name: Notification.Name("stripeCheckoutRequested"),
                    object: url
                )
                // Fallback: open in external Safari after a brief delay
                // (SFSafariVC may not present if view hierarchy isn't ready)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    // If stripeCheckoutURL is still set, SFSafariVC didn't consume it
                    if self?.stripeCheckoutURL != nil {
                        self?.stripeCheckoutURL = nil
                        UIApplication.shared.open(url)
                    }
                }
            }
            return "Opening Stripe checkout. After payment, credits will be added automatically."
        }

        return "Stripe checkout link (external): \(checkoutURL)\nNote: Apple IAP remains the default in-app credit flow."
    }

    /// Build the `view` tool definition.
    /// The model calls this to view images — either from attachments or workspace files.
    private func makeViewTool() -> ToolDefinition {
        ToolDefinition(
            name: "view",
            description: "View an image by name or path. Returns auto-resized base64 image data for vision models. Only works with image files (jpg, png, gif, webp, heic, bmp, tiff, svg).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Image filename from attached files, or a workspace-relative file path"),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ]),
            overridesBuiltInTool: true,
            skipPermission: true,
            handler: { [weak self] args in
                guard let self else { return "Error: view model deallocated" }
                return await self.handleView(args)
            }
        )
    }

    /// Handle `view` tool call — load and return image data.
    /// Checks attachments first, then workspace files.
    private func handleView(_ args: JSONValue) async -> String {
        guard case .object(let dict) = args,
              case .string(let path) = dict["path"] else {
            return "Error: missing 'path' parameter"
        }

        // Check if it's an image by extension
        let ext = (path as NSString).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg"]
        guard imageExtensions.contains(ext) else {
            return "Error: '\(path)' is not an image file. The view tool only supports images (\(imageExtensions.sorted().joined(separator: ", ")))."
        }

        // Try attachment store first
        do {
            let result = try await attachmentStore.loadSmart(name: path)
            return result.modelDescription
        } catch AttachmentError.notFound {
            // Not in attachments — try workspace path
        } catch {
            return "Error: \(error)"
        }

        // Try workspace file
        guard let workspaceURL else {
            return "Error: no workspace configured"
        }
        let fileURL = workspaceURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return "Error: image not found at '\(path)'"
        }

        // Load image directly and resize
        guard let data = try? Data(contentsOf: fileURL) else {
            return "Error: failed to read image at '\(path)'"
        }
        let mime = AttachmentStore.mimeType(for: ext)
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            let maxDim: CGFloat = 768
            let size = image.size
            let maxSide = max(size.width, size.height)
            let targetSize: CGSize
            if maxSide > maxDim {
                let scale = maxDim / maxSide
                targetSize = CGSize(width: size.width * scale, height: size.height * scale)
            } else {
                targetSize = size
            }
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let jpegData = renderer.jpegData(withCompressionQuality: 0.7) { ctx in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            return "[image:\(path)] data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        }
        #endif
        return "[image:\(path)] data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: - Convert to Markdown Tool

    /// Build the `convert_to_markdown` tool — converts files (PDF, DOC, etc.) to markdown text.
    private func makeConvertToMarkdownTool() -> ToolDefinition {
        ToolDefinition(
            name: "convert_to_markdown",
            description: "Convert a file to markdown text. Supports PDF (text extraction), and common text formats. Use this for non-image files that need content reading.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Filename from attached files, or a workspace-relative file path"),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ]),
            skipPermission: true,
            handler: { [weak self] args in
                guard let self else { return "Error: view model deallocated" }
                return await self.handleConvertToMarkdown(args)
            }
        )
    }

    /// Handle `convert_to_markdown` tool call.
    private func handleConvertToMarkdown(_ args: JSONValue) async -> String {
        guard case .object(let dict) = args,
              case .string(let path) = dict["path"] else {
            return "Error: missing 'path' parameter"
        }

        // Try attachment store first
        do {
            let result = try await attachmentStore.loadSmart(name: path)
            return formatSmartResult(path: path, result: result)
        } catch AttachmentError.notFound {
            // Not in attachments — try workspace
        } catch {
            return "Error: \(error)"
        }

        // Try workspace file
        guard let workspaceURL else {
            return "Error: no workspace configured"
        }
        let fileURL = workspaceURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return "Error: file not found at '\(path)'"
        }

        let ext = (path as NSString).pathExtension.lowercased()
        let mime = AttachmentStore.mimeType(for: ext)

        // PDF — extract text via PDFKit
        if mime == "application/pdf" {
            #if canImport(PDFKit)
            if let document = PDFDocument(url: fileURL) {
                let pageCount = document.pageCount
                let maxPages = min(pageCount, 10)
                var textContent = ""
                for i in 0..<maxPages {
                    if let page = document.page(at: i), let text = page.string {
                        if !textContent.isEmpty { textContent += "\n\n" }
                        textContent += "--- Page \(i + 1) ---\n\(text)"
                    }
                }
                if pageCount > maxPages {
                    textContent += "\n\n[... \(pageCount - maxPages) more pages not shown]"
                }
                return "# \(path)\n\n> PDF, \(pageCount) pages\n\n\(textContent)"
            }
            #endif
            return "Error: failed to read PDF at '\(path)'"
        }

        // Text-like files — read directly
        if mime.hasPrefix("text/") || AttachmentStore.isTextMimeType(mime) {
            if let data = try? Data(contentsOf: fileURL),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "Error: failed to read text from '\(path)'"
        }

        // Unsupported format — try external converter (convertio.co site adapter)
        if let converter = fileConverter {
            do {
                let result = try await converter(fileURL.path, "txt")
                // Read the converted file
                if result.hasPrefix("Error") {
                    return result
                }
                // result is the download path — read the text from it
                if let data = try? Data(contentsOf: URL(fileURLWithPath: result)),
                   let text = String(data: data, encoding: .utf8) {
                    return text
                }
                return result
            } catch {
                return "Error: external conversion failed — \(error.localizedDescription)"
            }
        }

        return "Error: unsupported format '\(mime)' for markdown conversion. Supported: PDF, text files. Set up the convertio.co site adapter for other formats."
    }

    private func formatSmartResult(path: String, result: SmartAttachmentResult) -> String {
        switch result {
        case .pdfText(let text, let pageCount):
            return "# \(path)\n\n> PDF, \(pageCount) pages\n\n\(text)"
        case .text(let text):
            return text
        case .videoMetadata(let duration, let width, let height, _, _):
            return "# \(path)\n\nVideo: \(width)×\(height), \(String(format: "%.1f", duration))s"
        case .image:
            return "Error: '\(path)' is an image. Use the `view` tool instead."
        case .binary(_, let mimeType):
            return "Error: unsupported format '\(mimeType)' for markdown conversion"
        }
    }

    // MARK: - Start Coding Task Tool

    private func makeStartCodingTaskTool() -> ToolDefinition {
        ToolDefinition(
            name: "start_coding_task",
            description: "Start a coding task for a project. Creates a GitHub repo, creates an issue with the task spec, assigns the coding agent, and activates the CI/CD pipeline. Returns the repo URL and issue URL.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "appName": .object([
                        "type": .string("string"),
                        "description": .string("Display name for the app (e.g., \"Weather App\")")
                    ]),
                    "taskDescription": .object([
                        "type": .string("string"),
                        "description": .string("Detailed description of what the app should do. Will be used as the issue body for the coding agent.")
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("AI model for the coding agent. Supported: \"claude-sonnet-4.5\", \"claude-opus-4.5\", \"claude-opus-4.6\", \"gpt-5.2-codex\", or \"\" for Auto.")
                    ])
                ]),
                "required": .array([.string("appName"), .string("taskDescription")])
            ]),
            skipPermission: true,
            handler: { [weak self] args in
                guard let self else { return "Error: view model deallocated" }
                return await self.handleStartCodingTask(args)
            }
        )
    }

    private func handleStartCodingTask(_ args: JSONValue) async -> String {
        guard case .object(let dict) = args,
              case .string(let appName) = dict["appName"],
              case .string(let taskDescription) = dict["taskDescription"] else {
            return "Error: 'appName' and 'taskDescription' are required"
        }
        let model: String
        if case .string(let m) = dict["model"] { model = m } else { model = "" }
        let userId: String
        if case .agent(let config) = mode { userId = config.userId ?? "default" } else { userId = "default" }

        nonisolated(unsafe) let handler = getOrCreateProjectTaskHandler()
        return await handler.createProject(appName: appName, taskDescription: taskDescription, model: model, userId: userId)
    }
}

// MARK: - ChatMessage Helpers

extension ChatMessage {
    /// Get the full text content by joining all text/markdown blocks.
    public var fullText: String {
        content.compactMap { block in
            switch block {
            case .text(let s), .markdown(let s): return s
            case .code(let s, _): return "```\n\(s)\n```"
            case .mermaid(let s): return "```mermaid\n\(s)\n```"
            default: return nil
            }
        }.joined(separator: "\n\n")
    }
}

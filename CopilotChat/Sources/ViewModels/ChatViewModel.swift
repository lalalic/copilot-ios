import Foundation
import SwiftUI
import CopilotSDK

// MARK: - Chat Mode

/// The operating mode for the chat — either interactive session or autonomous agent.
public enum ChatMode: Sendable {
    /// Interactive back-and-forth session.
    case session(SessionConfig)
    /// Autonomous agent with `send_response` and `ask_user` tools.
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
    /// Model called `ask_user` — waiting for user reply.
    case waitingForUser(question: String)
    /// Model called `ask_questions` — waiting for structured user replies.
    case waitingForQuestions([AskQuestionItem])
    /// An error occurred.
    case error(String)
}

// MARK: - Chat View Model

/// Unified view model for both session and agent chat modes.
/// Handles connection, message dispatch, streaming, tool calls, and todo list.
@MainActor
public final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var messages: [ChatMessage] = []
    @Published public var toolCalls: [ToolCallInfo] = []
    @Published public var todoItems: [TodoItem] = []
    @Published public var chatState: ChatState = .disconnected
    @Published public var inputText: String = ""
    @Published public var isListening: Bool = false

    // MARK: - Configuration

    public let inputModes: InputMode
    private let transport: Transport
    private let mode: ChatMode

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

    // MARK: - Init

    /// Create a chat view model.
    /// - Parameters:
    ///   - transport: WebSocket transport to connect to the relay.
    ///   - mode: `.session(config)` or `.agent(config)`.
    ///   - inputModes: Which input modes are available (.text, .speech, .attachment).
    public init(
        transport: Transport,
        mode: ChatMode,
        inputModes: InputMode = .textAndSpeech
    ) {
        self.transport = transport
        self.mode = mode
        self.inputModes = inputModes
    }

    deinit {
        agentTask?.cancel()
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

        // Inject manage_todo_list tool
        var config = config
        config.tools = (config.tools ?? []) + [makeTodoTool()]

        let session = try await client.createSession(config: config)
        self.session = session

        // Subscribe to events
        await subscribeToEvents(session: session)
        chatState = .idle
    }

    // MARK: - Agent Mode

    private func connectAgent(config: inout AgentConfig) async throws {
        guard let client else { return }

        // Inject manage_todo_list tool
        config.tools.append(makeTodoTool())

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
        chatState = .idle
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

        // Tool execution tracking
        await session.on(.toolExecutionStart) { [weak self] event in
            guard let self else { return }
            if case .object(let data) = event.data {
                let toolName = data["toolName"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "unknown"
                let toolCallId = data["toolCallId"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? UUID().uuidString
                let args = data["arguments"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
                Task { @MainActor in
                    self.toolCalls.append(ToolCallInfo(id: toolCallId, name: toolName, arguments: args))
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

        // Add user message to the chat
        let userMessage = ChatMessage(
            role: .user,
            content: [.text(text)]
        )
        messages.append(userMessage)

        switch chatState {
        case .waitingForUser:
            // Resume ask_user continuation
            askUserContinuation?.resume(returning: text)
            askUserContinuation = nil
            chatState = .working

        case .waitingForQuestions(let questions):
            guard let first = questions.first else { return }
            submitAskQuestions([
                first.header: AskQuestionAnswer(selected: [], freeText: text, skipped: false)
            ])

        case .working:
            // Steer — inject immediate message
            do {
                try await session?.steer(prompt: text)
            } catch {
                appendSystemMessage("Steer failed: \(error.localizedDescription)")
            }

        case .idle:
            // Normal prompt
            chatState = .working
            await sendPrompt(text)

        default:
            break
        }
    }

    /// Send a message with an image attachment.
    public func sendWithImage(_ imageData: Data, mimeType: String, text: String) async {
        guard let session else { return }

        // Add user message
        var blocks: [ChatMessage.ContentBlock] = [.image(imageData, mimeType: mimeType)]
        if !text.isEmpty {
            blocks.insert(.text(text), at: 0)
        }
        messages.append(ChatMessage(role: .user, content: blocks))

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
        switch mode {
        case .session:
            do {
                try await session?.send(prompt: text)
            } catch {
                appendSystemMessage("Send failed: \(error.localizedDescription)")
                chatState = .idle
            }

        case .agent:
            if let agent, !agent.isRunning {
                // Start agent loop with the initial prompt
                agentTask = Task {
                    do {
                        try await agent.start(prompt: text)
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
                    try await session?.steer(prompt: text)
                } catch {
                    appendSystemMessage("Steer failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Agent Callbacks

    private func handleAgentResponse(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // send_response delivers a final response — add as assistant message
        let blocks = parseContentBlocks(trimmed)
        let msg = ChatMessage(role: .assistant, content: blocks)
        messages.append(msg)
    }

    private func handleAgentAskUser(_ question: String) async -> String {
        // Update state on main thread, then wait for user to reply
        chatState = .waitingForUser(question: question)

        // Add the question as an assistant message
        let blocks = parseContentBlocks(question)
        messages.append(ChatMessage(role: .assistant, content: blocks))

        // Wait for user reply via continuation
        return await withCheckedContinuation { continuation in
            self.askUserContinuation = continuation
        }
    }

    private func handleAgentAskQuestions(_ payload: JSONValue) async -> JSONValue {
        let questions = parseAskQuestions(payload)
        guard !questions.isEmpty else {
            return .object([:])
        }

        chatState = .waitingForQuestions(questions)
        activeQuestions = questions
        messages.append(ChatMessage(role: .assistant, content: [.text("Please answer the questions below.")]))

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

        askQuestionsContinuation?.resume(returning: .object(result))
        askQuestionsContinuation = nil
        activeQuestions = []
        chatState = .working
    }

    public func skipAskQuestions() {
        var skipped: [String: AskQuestionAnswer] = [:]
        for question in activeQuestions {
            skipped[question.header] = AskQuestionAnswer(selected: [], freeText: nil, skipped: true)
        }
        submitAskQuestions(skipped)
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
            messages.append(ChatMessage(role: .assistant, content: blocks, isStreaming: true))
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
                }
            } else {
                messages[lastIndex].content = parseContentBlocks(trimmed)
                messages[lastIndex].isStreaming = false
            }
        } else {
            guard !trimmed.isEmpty else { return }
            let blocks = parseContentBlocks(trimmed)
            messages.append(ChatMessage(role: .assistant, content: blocks))
        }
    }

    /// Add a system message (for errors, status updates).
    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: [.text(text)]))
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

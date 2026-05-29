import Foundation
import SwiftUI
import Combine
import CopilotSDK
#if canImport(PDFKit)
import PDFKit
#endif

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
    /// Model called `ask_questions` — waiting for user reply.
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
    /// Filter deciding which notification types to show in chat.
    /// Returns true if the given type (e.g. "usage", "agent_progress", "build") should be displayed.
    public let notificationFilter: (String) -> Bool

    // MARK: - Direct Provider Runtime

    /// The provider-neutral runtime backing this chat.
    private var runtime: AgentSessionRuntime?
    private var runtimeSubscription: RuntimeSubscription?
    private var runtimeConfig: RuntimeSessionConfig?
    /// Continuation for ask_questions — resumed when user replies.
    private var askQuestionsTextContinuation: CheckedContinuation<String, Never>?
    /// Continuation for ask_questions — resumed when user submits structured replies.
    private var askQuestionsContinuation: CheckedContinuation<JSONValue, Never>?
    @Published public var activeQuestions: [AskQuestionItem] = []
    
    /// Workspace directory on device for reading templates.
    public let workspaceURL: URL?

    /// External file converter — set by the app to delegate conversion to a site adapter (e.g., convertio.co).
    /// Takes (filePath, outputFormat) and returns the path to the converted file or an error string.
    public var fileConverter: (@Sendable (String, String) async throws -> String)?

    /// Logs chat messages to .neo/reports/sessions/ as JSONL.
    private var sessionLogger: ChatSessionLogger?

    /// Diagnostic: whether runtime is non-nil (for testing tools).
    public var hasRuntimeForDiag: Bool { runtime != nil }

    /// Whether speech input should record audio for server-side transcription
    /// (e.g., NeoDesktop mode uses mlx-whisper on the Mac).
    /// When true, InputBar records audio and sends via sendAudio() instead of
    /// using on-device SFSpeechRecognizer.
    public var useServerTranscription: Bool = false

    /// Callback for channel-forwarded ask_questions in headless sessions.
    /// When set, questions are dispatched through this handler (e.g., to Discord/WeChat)
    /// instead of being auto-answered. The handler receives the question text for display.
    /// The session enters `.waitingForQuestions` and the next `channelSend` resumes the continuation.
    public var onChannelQuestions: ((_ questionText: String) async -> Void)?

    /// Clear all session history (JSONL files).
    public func clearSessionHistory() {
        sessionLogger?.clearHistory()
    }

    // MARK: - Init

    /// Create a chat view model backed by a provider runtime.
    /// Uses AgentSessionRuntime for all chat functionality.
    public init(
        runtime: AgentSessionRuntime,
        runtimeConfig: RuntimeSessionConfig,
        inputModes: InputMode = .textAndSpeech,
        usageTracker: UsageTracker = UsageTracker(),
        workspaceURL: URL? = nil,
        notificationFilter: @escaping (String) -> Bool = { _ in true }
    ) {
        self.inputModes = inputModes
        self.usageTracker = usageTracker
        self.workspaceURL = workspaceURL
        self.notificationFilter = notificationFilter
        self.runtime = runtime
        self.runtimeConfig = runtimeConfig

        if let workspaceURL {
            self.sessionLogger = ChatSessionLogger(workspaceURL: workspaceURL)
        }
    }

    /// Send APNs device token to relay for push notifications.
    public func setDeviceToken(_ token: String, apnsEnv: String? = nil, userId: String? = nil) async {
        // No longer needed — push notifications handled separately
    }

    /// Add a push notification as a system message in the chat.
    @MainActor
    public func addNotification(title: String, body: String, data: [String: Any] = [:]) {
        // Honor literal \n in body text
        let displayBody = body.replacingOccurrences(of: "\\n", with: "\n")

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
        let hasRuntime = runtime != nil
        return "runtime=\(hasRuntime) chatState=\(chatState)"
    }

    // MARK: - Connection

    /// Connect to the runtime and create a session.
    public func connect() async {
        guard chatState == .disconnected || chatState == .error("") || isErrorState else { return }
        chatState = .connecting

        guard let runtime, let config = runtimeConfig else {
            chatState = .error("No runtime configured")
            return
        }

        do {
            try await connectRuntime(runtime: runtime, config: config)
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
        if let sub = runtimeSubscription, let rt = runtime {
            rt.unsubscribe(sub)
            runtimeSubscription = nil
        }
        chatState = .disconnected
    }

    /// Destroy session and clean up.
    public func destroy() {
        if let sub = runtimeSubscription, let rt = runtime {
            rt.unsubscribe(sub)
            runtimeSubscription = nil
        }
        if let runtime {
            Task { await runtime.destroy() }
        }
        chatState = .disconnected
    }

    // MARK: - Direct Provider Runtime

    private func connectRuntime(runtime: AgentSessionRuntime, config: RuntimeSessionConfig) async throws {
        subscribeToRuntimeEvents(runtime: runtime)
        try await runtime.createSession(config: config)
        usageTracker.resetSession()
        loadChatHistory()
        chatState = .idle
    }

    private func subscribeToRuntimeEvents(runtime: AgentSessionRuntime) {
        let sub = runtime.subscribe { [weak self] event in
            Task { @MainActor in
                self?.handleRuntimeEvent(event)
            }
        }
        runtimeSubscription = sub
    }

    @MainActor
    private func handleRuntimeEvent(_ event: RuntimeEvent) {
        switch event {
        case .assistantTextDelta(let delta):
            appendOrUpdateAssistantDelta(delta.text)

        case .assistantMessageComplete(let complete):
            finalizeAssistantMessage(complete.content)

        case .turnStart:
            chatState = .working

        case .turnEnd:
            // Only go idle if not waiting for user input
            if case .waitingForUser = chatState { return }
            if case .waitingForQuestions = chatState { return }
            chatState = .idle

        case .toolStart(let info):
            toolCalls.append(ToolCallInfo(id: info.toolCallId, name: info.toolName, arguments: info.arguments))
            if toolCalls.count > 5 {
                toolCalls.removeFirst(toolCalls.count - 5)
            }

        case .toolComplete(let info):
            if let idx = toolCalls.firstIndex(where: { $0.id == info.toolCallId }) {
                toolCalls[idx].status = .completed
                toolCalls[idx].result = info.result
                let name = toolCalls[idx].name
                let args = toolCalls[idx].arguments ?? ""
                let truncated = String((info.result ?? "").prefix(500))
                var parts = "[\(name)]"
                if !args.isEmpty { parts += " \(args)" }
                if !truncated.isEmpty { parts += "\n\(truncated)" }
                sessionLogger?.log(role: "tool_result", text: parts, project: projectScope)
            }

        case .toolUpdate:
            break // Not currently used in UI

        case .usageUpdate(let usage):
            usageTracker.record(
                model: usage.model,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens,
                cost: usage.cost
            )

        case .error(let runtimeError):
            chatState = .error(runtimeError.message)

        case .sessionIdle:
            if case .waitingForUser = chatState { return }
            if case .waitingForQuestions = chatState { return }
            chatState = .idle

        case .compactionStart:
            chatState = .compacting

        case .compactionComplete:
            if case .compacting = chatState {
                chatState = .working
            }

        case .userInputRequested(let request):
            let prompt = request.questions.map { $0.text }.joined(separator: "\n")
            chatState = .waitingForUser(question: prompt)
            if !prompt.isEmpty {
                let blocks = parseContentBlocks(prompt)
                messages.append(ChatMessage(role: .assistant, content: blocks, project: projectScope))
            }

        case .reasoningDelta, .reasoningComplete, .queueStateUpdate, .sessionRestored:
            break // Not surfaced in current UI
        }
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
    /// 2. ask_questions reply — resumes the waiting continuation
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

        // Snapshot attachments as RuntimeAttachments before clearing,
        // so .idle → sendPrompt can forward bytes to the runtime.
        let attachmentSnapshot: [RuntimeAttachment]? = {
            let entries = attachmentStore.entries
            guard !entries.isEmpty else { return nil }
            return entries.compactMap { entry in
                guard let data = try? Data(contentsOf: entry.fileURL) else { return nil }
                return RuntimeAttachment(name: entry.displayName, data: data, mimeType: entry.mimeType)
            }
        }()

        // Clear attachments after snapshotting
        if attachmentDesc != nil {
            attachmentStore.clear()
        }

        switch chatState {
        case .waitingForUser:
            if let continuation = askQuestionsTextContinuation {
                // Local session path — resume the async continuation
                continuation.resume(returning: promptText)
                askQuestionsTextContinuation = nil
            } else if let runtime {
                // Remote runtime path (e.g. NeoDesktopRuntime) — POST answer via relay
                Task {
                    try? await runtime.respondToUserInput(
                        requestId: "ask_questions",
                        responses: ["ask_questions": promptText]
                    )
                }
            }
            chatState = .working

        case .waitingForQuestions(let questions):
            guard let first = questions.first else { return }
            submitAskQuestions([
                first.header: AskQuestionAnswer(selected: [], freeText: promptText, skipped: false)
            ])

        case .working:
            // Steer — inject immediate message
            do {
                try await runtime?.steer(message: promptText)
            } catch {
                appendSystemMessage("Steer failed: \(error.localizedDescription)")
                chatState = .idle
            }

        case .idle:
            // Normal prompt
            chatState = .working
            await sendPrompt(promptText, attachments: attachmentSnapshot)

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
            if let runtime {
                Task { [weak self] in
                    do {
                        try await runtime.send(prompt: trimmed, attachments: nil)
                    } catch {
                        await MainActor.run {
                            self?.appendSystemMessage("Send failed: \(error.localizedDescription)")
                            self?.chatState = .idle
                        }
                    }
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

        // Answer pending questions to unblock the model.
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
            askQuestionsTextContinuation?.resume(returning: trimmed)
            askQuestionsTextContinuation = nil
            chatState = .working
            needsSend = false
        default:
            needsSend = true
        }

        if needsSend {
            chatState = .working
            guard let runtime else {
                chatState = .idle
                return "no-runtime"
            }
            do {
                try await runtime.send(prompt: trimmed, attachments: nil)
            } catch {
                let msg = error.localizedDescription
                appendSystemMessage("Error: \(msg)")
                chatState = .idle
                return "error: \(msg)"
            }
        }

        // Wait for chatState to leave .working (idle, waitingForUser, error, etc.)
        // 180s timeout for operations that involve tool calls
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
    /// Send a message with an image attachment.
    public func sendWithImage(_ imageData: Data, mimeType: String, text: String) async {
        guard let runtime else { return }

        // Add user message
        var blocks: [ChatMessage.ContentBlock] = [.image(imageData, mimeType: mimeType)]
        if !text.isEmpty {
            blocks.insert(.text(text), at: 0)
        }
        messages.append(ChatMessage(role: .user, content: blocks, project: projectScope))

        chatState = .working
        let attachment = RuntimeAttachment(name: "image.\(mimeType.hasSuffix("png") ? "png" : "jpg")", data: imageData, mimeType: mimeType)
        do {
            try await runtime.send(prompt: text, attachments: [attachment])
        } catch {
            appendSystemMessage("Send failed: \(error.localizedDescription)")
            chatState = .idle
        }
    }

    /// Send recorded audio for server-side transcription (mlx-whisper on Mac).
    public func sendAudio(_ audioData: Data) async {
        guard let runtime else { return }

        // Add user message indicating audio was sent
        messages.append(ChatMessage(role: .user, content: [.text("🎙️ [Voice message]")], project: projectScope))
        sessionLogger?.log(role: "user", text: "🎙️ [Voice message]", project: projectScope)

        chatState = .working
        let attachment = RuntimeAttachment(name: "recording.m4a", data: audioData, mimeType: "audio/mp4")
        do {
            try await runtime.send(prompt: "", attachments: [attachment])
        } catch {
            appendSystemMessage("Audio send failed: \(error.localizedDescription)")
            chatState = .idle
        }
    }

    // MARK: - Private Send Helpers

    private func sendPrompt(_ text: String, attachments preSnapped: [RuntimeAttachment]? = nil) async {
        // Inject project context if a project is scoped
        let effectiveText: String
        if let project = projectScope {
            effectiveText = "[Project: \(project)] \(text)"
        } else {
            effectiveText = text
        }

        guard let runtime else {
            appendSystemMessage("No runtime configured")
            chatState = .idle
            return
        }

        // Use the pre-snapped attachments if provided (callers may have already
        // cleared the store before invoking sendPrompt). Otherwise read live.
        let attachments: [RuntimeAttachment]? = preSnapped ?? {
            let entries = attachmentStore.entries
            guard !entries.isEmpty else { return nil }
            return entries.compactMap { entry in
                guard let data = try? Data(contentsOf: entry.fileURL) else { return nil }
                return RuntimeAttachment(name: entry.displayName, data: data, mimeType: entry.mimeType)
            }
        }()

        do {
            try await runtime.send(prompt: effectiveText, attachments: attachments)
        } catch {
            appendSystemMessage("Send failed: \(error.localizedDescription)")
            chatState = .idle
        }
    }

    // MARK: - Ask Questions Support

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
            continuation.resume(returning: .object(result))
            askQuestionsContinuation = nil
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
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].isStreaming {
            // Append to existing streaming message using raw text buffer
            // to preserve all whitespace (newlines, spaces) exactly as streamed
            let raw = (messages[lastIndex].streamingRawText ?? "") + delta
            messages[lastIndex].streamingRawText = raw
            messages[lastIndex].content = [.text(raw)]
        } else {
            // Start a new streaming message — skip if purely whitespace
            let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDelta.isEmpty else { return }
            messages.append(ChatMessage(role: .assistant, content: [.text(delta)], isStreaming: true, project: projectScope))
            messages[messages.count - 1].streamingRawText = delta
        }
    }

    /// Finalize a streaming message or add a complete assistant message.
    private func finalizeAssistantMessage(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].isStreaming {
            // Use the raw streaming buffer if available (preserves newlines),
            // otherwise fall back to the finalization content
            let finalText = messages[lastIndex].streamingRawText?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? trimmed
            messages[lastIndex].streamingRawText = nil

            if finalText.isEmpty {
                messages.remove(at: lastIndex)
            } else {
                messages[lastIndex].content = parseContentBlocks(finalText)
                messages[lastIndex].isStreaming = false
                sessionLogger?.log(role: "assistant", text: finalText, project: projectScope)
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
            description: "Open external payment checkout for credits. Use when credits are low or user requests top-up.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "amount_usd": .object([
                        "type": .string("number"),
                        "description": .string("Optional requested top-up amount in USD"),
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Why top-up is needed (e.g. credits exhausted, user requested)"),
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
        // Payment link URL — set via UserDefaults from runtime config
        let base = (UserDefaults.standard.string(forKey: "stripePaymentLink") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base.hasPrefix("https://") else {
            return "External payment checkout is not configured."
        }

        var requestedAmount: Double?
        var reason = ""
        if case .object(let dict) = args {
            if case .double(let d) = dict["amount_usd"] { requestedAmount = d }
            else if case .int(let i) = dict["amount_usd"] { requestedAmount = Double(i) }
            if case .string(let r) = dict["reason"] { reason = r }
        }

        let explicitPaymentIntent = reason.lowercased().contains("checkout") || reason.lowercased().contains("payment") || reason.lowercased().contains("top up") || reason.lowercased().contains("topup")
        if !usageTracker.isLowBalance && !usageTracker.hasInsufficientBalance && !explicitPaymentIntent {
            return "Balance is still sufficient ($\(String(format: "%.2f", usageTracker.balance))). No need to top up right now."
        }

        // Don't open if checkout already in progress
        if self.stripeCheckoutURL != nil {
            return "Payment checkout is already in progress."
        }

        var checkoutURL = base
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(deviceId, forKey: "pendingStripeCheckoutRef")

        // Handle {CLIENT_ID} token replacement
        if base.contains("{CLIENT_ID}") {
            checkoutURL = base.replacingOccurrences(of: "{CLIENT_ID}", with: deviceId)
        }

        if var components = URLComponents(string: checkoutURL) {
            var query = components.queryItems ?? []
            let existingKeys = Set(query.compactMap { $0.name })

            // Append client_reference_id if not already present and no token replacement
            if !existingKeys.contains("client_reference_id") && !base.contains("{CLIENT_ID}") {
                query.append(URLQueryItem(name: "client_reference_id", value: deviceId))
            } else if let existing = query.first(where: { $0.name == "client_reference_id" })?.value {
                UserDefaults.standard.set(existing, forKey: "pendingStripeCheckoutRef")
            }

            // Append amount_usd if not already present and requested
            if let requestedAmount, requestedAmount > 0, !existingKeys.contains("amount_usd") {
                query.append(URLQueryItem(name: "amount_usd", value: String(format: "%.2f", requestedAmount)))
            }
            components.queryItems = query
            checkoutURL = components.url?.absoluteString ?? checkoutURL
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
            return "Opening payment checkout. After payment, credits will be added automatically."
        }

        return "Payment checkout link: \(checkoutURL)"
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
            return "Error: '\(path)' is an image. Use the `describe_media` tool instead."
        case .binary(_, let mimeType):
            return "Error: unsupported format '\(mimeType)' for markdown conversion"
        }
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

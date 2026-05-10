import Foundation
import os

// MARK: - DirectProviderRuntime

/// Phase 2 runtime: executes chat sessions directly against provider APIs
/// without any relay server dependency.
///
/// Owns session lifecycle, prompt queueing, event emission, tool dispatch,
/// local persistence, and usage accounting.
public final class DirectProviderRuntime: AgentSessionRuntime, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.copilot-ios", category: "DirectProviderRuntime")

    // MARK: - Protocol Properties

    public let sessionId: String

    public var state: SessionState {
        get async {
            await MainActor.run { _state }
        }
    }

    public var currentModel: ModelInfo? {
        get async {
            await MainActor.run { _currentModel }
        }
    }

    // MARK: - Internal State

    @MainActor private var _state: SessionState = .disconnected
    @MainActor private var _currentModel: ModelInfo?

    private let credentialStore: CredentialStore
    private let modelRegistry: ModelRegistry
    private let sessionStore: SessionStore
    private let usageCalculator: UsageCalculator

    /// Registered provider adapters, keyed by provider ID.
    private var adapters: [String: ProviderAdapter] = [:]

    /// Current active adapter.
    private var activeAdapter: ProviderAdapter?

    /// Conversation history for the current session.
    private var conversationMessages: [ProviderMessage] = []

    /// Runtime messages for persistence.
    private var runtimeMessages: [RuntimeMessage] = []

    /// Tools available in this session.
    private var tools: [ToolDefinition] = []

    /// System message for this session.
    private var systemMessage: String?

    /// Current model ID.
    private var activeModelId: String?

    /// Active provider ID.
    private var activeProviderId: String?

    /// Current reasoning effort level.
    private var reasoningEffort: String?

    /// Current streaming task.
    private var streamingTask: Task<Void, Never>?

    /// Steering messages injected during tool execution.
    private var steerQueue: [String] = []

    /// Subscription management.
    private let subscriptionLock = NSLock()
    private var subscriptions: [RuntimeSubscription: @Sendable (RuntimeEvent) -> Void] = [:]

    /// Pending user input continuations.
    private var pendingInputContinuations: [String: CheckedContinuation<[String: String], Error>] = [:]

    /// Session name for persistence.
    private var sessionName: String?

    // MARK: - Init

    public init(
        credentialStore: CredentialStore,
        modelRegistry: ModelRegistry,
        sessionStore: SessionStore,
        sessionId: String = UUID().uuidString
    ) {
        self.credentialStore = credentialStore
        self.modelRegistry = modelRegistry
        self.sessionStore = sessionStore
        self.usageCalculator = UsageCalculator(modelRegistry: modelRegistry)
        self.sessionId = sessionId

        // Register default adapters
        let openai = OpenAIAdapter(usageCalculator: usageCalculator)
        let anthropic = AnthropicAdapter(usageCalculator: usageCalculator)
        let deepseek = OpenAIAdapter(
            providerId: "deepseek",
            displayName: "DeepSeek",
            defaultBaseURL: "https://api.deepseek.com",
            usageCalculator: usageCalculator
        )
        let xai = OpenAIAdapter(
            providerId: "xai",
            displayName: "xAI",
            defaultBaseURL: "https://api.x.ai/v1",
            usageCalculator: usageCalculator
        )
        // CCM relay (multiplexed OpenAI-compatible endpoint backed by
        // DeepSeek/Anthropic/Qwen behind a single bearer token). See design
        // doc `docs/direct-agent-runtime-design.md` Phase 2.
        let ccmRelay = RelayProviderAdapter(usageCalculator: usageCalculator)
        adapters["openai"] = openai
        adapters["anthropic"] = anthropic
        adapters["deepseek"] = deepseek
        adapters["xai"] = xai
        adapters[ccmRelay.providerId] = ccmRelay
    }

    /// Register a custom provider adapter.
    public func registerAdapter(_ adapter: ProviderAdapter) {
        adapters[adapter.providerId] = adapter
    }

    /// Sorted list of registered provider IDs (introspection / UI).
    public var registeredProviderIds: [String] {
        adapters.keys.sorted()
    }

    // MARK: - Session Lifecycle

    public func createSession(config: RuntimeSessionConfig) async throws {
        await MainActor.run { _state = .connecting }

        // Resolve provider and model — use ModelRegistry defaults if not specified
        let resolvedModel = config.model ?? modelRegistry.defaultModelId
        let providerId = config.provider ?? resolveProvider(for: resolvedModel)
        guard let adapter = adapters[providerId] else {
            throw DirectProviderError.unknownProvider(providerId)
        }

        guard credentialStore.getAPIKey(forProviderKey: providerId) != nil || config.providerConfig?.apiKey != nil else {
            throw DirectProviderError.noCredentials(providerId)
        }

        activeAdapter = adapter
        activeProviderId = providerId
        activeModelId = resolvedModel
        systemMessage = config.systemMessage
        reasoningEffort = config.reasoningEffort
        tools = config.tools ?? []
        sessionName = config.sessionName ?? "default"

        // Resolve model info
        await MainActor.run {
            _currentModel = modelRegistry.model(provider: providerId, id: resolvedModel)
        }

        // Create session in store
        if let name = sessionName, !sessionStore.sessionExists(name: name) {
            try? sessionStore.createSession(name: name, model: resolvedModel)
        }

        conversationMessages = []
        runtimeMessages = []
        usageCalculator.resetSession()

        await MainActor.run { _state = .idle }

        Self.logger.info("Session created: provider=\(providerId), model=\(config.model ?? "default")")
    }

    public func restoreSession(name: String) async throws {
        await MainActor.run { _state = .connecting }

        let data = try sessionStore.loadSession(name: name)
        sessionName = name
        runtimeMessages = data.messages

        // Rebuild conversation messages from runtime messages
        conversationMessages = data.messages.map { msg -> ProviderMessage in
            let role: ProviderMessage.Role
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool: role = .tool
            case .system: role = .system
            }
            return ProviderMessage(
                role: role,
                content: [.text(msg.content)],
                toolCallId: msg.toolResult?.toolCallId
            )
        }

        // If there's a compaction summary, inject it into the system message
        if let summary = data.summary, let existing = systemMessage {
            systemMessage = existing + "\n\n<conversation-summary>\n\(summary)\n</conversation-summary>"
        } else if let summary = data.summary {
            systemMessage = "<conversation-summary>\n\(summary)\n</conversation-summary>"
        }

        emit(.sessionRestored(.init(sessionName: name, messageCount: data.messages.count)))
        await MainActor.run { _state = .idle }

        Self.logger.info("Session restored: \(name), \(data.messages.count) messages")
    }

    public func send(prompt: String, attachments: [RuntimeAttachment]?) async throws {
        Self.logger.info("[SEND] start: prompt=\(prompt.prefix(50))")
        guard let adapter = activeAdapter,
              let providerId = activeProviderId,
              let modelId = activeModelId else {
            Self.logger.error("[SEND] no active session")
            throw DirectProviderError.noActiveSession
        }

        guard let apiKey = credentialStore.getAPIKey(forProviderKey: providerId) else {
            Self.logger.error("[SEND] no credentials for \(providerId)")
            throw DirectProviderError.noCredentials(providerId)
        }

        Self.logger.info("[SEND] provider=\(providerId) model=\(modelId) reasoning=\(self.reasoningEffort ?? "nil")")
        await MainActor.run { _state = .working }

        // Build user message
        var contentParts: [ProviderMessage.ContentPart] = [.text(prompt)]
        if let attachments {
            for attachment in attachments where attachment.isImage {
                contentParts.append(.image(data: attachment.data, mimeType: attachment.mimeType))
            }
        }

        let userMessage = ProviderMessage(role: .user, content: contentParts)
        conversationMessages.append(userMessage)
        runtimeMessages.append(RuntimeMessage(role: .user, content: prompt))

        // Build provider config
        let baseURL = credentialStore.getBaseURL(for: CredentialStore.Provider(rawValue: providerId) ?? .custom)
        let requestConfig = ProviderRequestConfig(
            apiKey: apiKey,
            baseURL: baseURL,
            maxTokens: (await currentModel)?.maxOutputTokens,
            reasoningEffort: reasoningEffort
        )

        // Convert tools to provider format
        let providerTools = tools.map { ProviderToolDefinition(from: $0) }

        // Run the agent loop
        Self.logger.info("[SEND] launching agent loop task")
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                Self.logger.info("[AGENT-LOOP] starting")
                try await self.runAgentLoop(
                    adapter: adapter,
                    model: modelId,
                    requestConfig: requestConfig,
                    providerTools: providerTools,
                    onEvent: { [weak self] event in
                        self?.emit(event)
                    }
                )
                Self.logger.info("[AGENT-LOOP] completed successfully")
            } catch {
                Self.logger.error("[AGENT-LOOP] error: \(error.localizedDescription)")
                if !Task.isCancelled {
                    self.emit(.error(.init(message: error.localizedDescription)))
                    Task { @MainActor in self._state = .error(error.localizedDescription) }
                }
            }
        }
        Self.logger.info("[SEND] awaiting task completion")
        await streamingTask?.value
        Self.logger.info("[SEND] done")
    }

    public func steer(message: String) async throws {
        steerQueue.append(message)
    }

    public func abort() async {
        streamingTask?.cancel()
        streamingTask = nil
        await activeAdapter?.abort()
        await MainActor.run { _state = .idle }
    }

    public func destroy() async {
        await abort()
        // Persist remaining messages
        if let name = sessionName, !runtimeMessages.isEmpty {
            try? sessionStore.appendMessages(runtimeMessages, to: name)
        }
        activeAdapter = nil
        activeProviderId = nil
        activeModelId = nil
        conversationMessages = []
        runtimeMessages = []
        await MainActor.run { _state = .disconnected }
    }

    // MARK: - Subscriptions

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (RuntimeEvent) -> Void) -> RuntimeSubscription {
        let sub = RuntimeSubscription()
        subscriptionLock.lock()
        subscriptions[sub] = handler
        subscriptionLock.unlock()
        return sub
    }

    public func unsubscribe(_ subscription: RuntimeSubscription) {
        subscriptionLock.lock()
        subscriptions.removeValue(forKey: subscription)
        subscriptionLock.unlock()
    }

    // MARK: - User Input

    public func respondToUserInput(requestId: String, responses: [String: String]) async throws {
        if let continuation = pendingInputContinuations.removeValue(forKey: requestId) {
            continuation.resume(returning: responses)
        }
    }

    // MARK: - History

    public func getMessages() async throws -> [RuntimeMessage] {
        if let name = sessionName, let data = try? sessionStore.loadSession(name: name) {
            return data.messages
        }
        return runtimeMessages
    }

    public func clearHistory() async throws {
        if let name = sessionName {
            try sessionStore.deleteSession(name: name)
            try sessionStore.createSession(name: name, model: activeModelId)
        }
        conversationMessages = []
        runtimeMessages = []
    }

    // MARK: - Agent Loop

    /// Run the agent loop: send to provider, handle tool calls, repeat until done.
    private func runAgentLoop(
        adapter: ProviderAdapter,
        model: String,
        requestConfig: ProviderRequestConfig,
        providerTools: [ProviderToolDefinition],
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws {
        var continueLoop = true

        // Use a class-based accumulator to satisfy Sendable closure requirements
        let accumulator = StreamAccumulator()

        while continueLoop && !Task.isCancelled {
            continueLoop = false
            accumulator.reset()

            // Inject any steer messages
            for steerMsg in steerQueue {
                conversationMessages.append(ProviderMessage(role: .user, text: steerMsg))
            }
            steerQueue.removeAll()

            try await adapter.streamCompletion(
                messages: conversationMessages,
                model: model,
                systemMessage: systemMessage,
                tools: providerTools,
                config: requestConfig
            ) { event in
                switch event {
                case .assistantTextDelta(let delta):
                    accumulator.appendText(delta.text)

                case .reasoningDelta(let delta):
                    accumulator.appendReasoning(delta.text)

                case .toolComplete(let tc):
                    // Accumulate tool calls for execution
                    accumulator.addToolCall(ProviderToolCall(id: tc.toolCallId, name: tc.toolName, arguments: tc.result ?? "{}"))

                default:
                    break
                }
                // Forward all events to subscribers
                onEvent(event)
            }

            let accumulatedText = accumulator.text
            let accumulatedReasoning = accumulator.reasoning
            let pendingToolCalls = accumulator.toolCalls

            // If we got tool calls, execute them and loop
            if !pendingToolCalls.isEmpty {
                // Record assistant message with tool calls (include reasoning for DeepSeek)
                let assistantMsg = ProviderMessage(
                    role: .assistant,
                    content: accumulatedText.isEmpty ? [] : [.text(accumulatedText)],
                    toolCalls: pendingToolCalls,
                    reasoningContent: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning
                )
                conversationMessages.append(assistantMsg)

                let toolCallRecords = pendingToolCalls.map {
                    RuntimeMessage.ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments)
                }
                runtimeMessages.append(RuntimeMessage(
                    role: .assistant,
                    content: accumulatedText,
                    model: model,
                    toolCalls: toolCallRecords
                ))

                // Execute each tool call
                for tc in pendingToolCalls {
                    guard !Task.isCancelled else { break }

                    let result = await executeTool(name: tc.name, arguments: tc.arguments)
                    let isError = result.hasPrefix("Error:")

                    // Emit tool start/complete for tools that were batched
                    onEvent(.toolStart(.init(toolCallId: tc.id, toolName: tc.name, arguments: tc.arguments)))
                    onEvent(.toolComplete(.init(toolCallId: tc.id, toolName: tc.name, result: result, isError: isError)))

                    // Add tool result to conversation
                    conversationMessages.append(ProviderMessage(
                        role: .tool,
                        content: [.text(result)],
                        toolCallId: tc.id
                    ))

                    runtimeMessages.append(RuntimeMessage(
                        role: .tool,
                        content: result,
                        toolResult: .init(toolCallId: tc.id, toolName: tc.name, content: result, isError: isError)
                    ))
                }

                continueLoop = true
            } else if !accumulatedText.isEmpty {
                // Record final assistant message
                conversationMessages.append(ProviderMessage(role: .assistant, text: accumulatedText))
                runtimeMessages.append(RuntimeMessage(role: .assistant, content: accumulatedText, model: model))
            }
        }

        // Persist messages
        if let name = sessionName {
            try? sessionStore.appendMessages(runtimeMessages, to: name)
        }

        await MainActor.run { _state = .idle }
    }

    /// Execute a tool by name.
    private func executeTool(name: String, arguments: String) async -> String {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return "Error: Unknown tool '\(name)'"
        }

        do {
            // Parse arguments JSON
            let argsValue: JSONValue
            if let data = arguments.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let dict = json as? [String: Any] {
                argsValue = JSONValue.from(dict)
            } else {
                argsValue = .object([:])
            }

            let result = try await tool.handler(argsValue)
            return result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func emit(_ event: RuntimeEvent) {
        subscriptionLock.lock()
        let handlers = Array(subscriptions.values)
        subscriptionLock.unlock()
        for handler in handlers {
            handler(event)
        }
    }

    /// Resolve provider from model ID.
    private func resolveProvider(for modelId: String?) -> String {
        guard let modelId else { return "openai" }

        let lower = modelId.lowercased()
        if lower.contains("claude") { return "anthropic" }
        if lower.contains("gemini") { return "google" }
        if lower.contains("grok") { return "xai" }
        if lower.contains("deepseek") { return "deepseek" }
        return "openai"
    }
}

// MARK: - JSONValue.from(_:)

extension JSONValue {
    /// Create a JSONValue from a native dictionary.
    static func from(_ dict: [String: Any]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            result[key] = JSONValue.from(any: value)
        }
        return .object(result)
    }

    /// Create a JSONValue from any native value.
    static func from(any value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let b as Bool: return .bool(b)
        case let arr as [Any]: return .array(arr.map { JSONValue.from(any: $0) })
        case let dict as [String: Any]: return .from(dict)
        case is NSNull: return .null
        default:
            if let s = value as? CustomStringConvertible {
                return .string(s.description)
            }
            return .null
        }
    }
}

// MARK: - StreamAccumulator

/// Thread-safe accumulator for streaming completion events.
private final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var _reasoning = ""
    private var _toolCalls: [ProviderToolCall] = []

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return _text
    }

    var reasoning: String {
        lock.lock()
        defer { lock.unlock() }
        return _reasoning
    }

    var toolCalls: [ProviderToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return _toolCalls
    }

    func appendText(_ text: String) {
        lock.lock()
        _text += text
        lock.unlock()
    }

    func appendReasoning(_ text: String) {
        lock.lock()
        _reasoning += text
        lock.unlock()
    }

    func addToolCall(_ tc: ProviderToolCall) {
        lock.lock()
        _toolCalls.append(tc)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        _text = ""
        _reasoning = ""
        _toolCalls = []
        lock.unlock()
    }
}

// MARK: - Errors

public enum DirectProviderError: Error, LocalizedError {
    case noActiveSession
    case unknownProvider(String)
    case noCredentials(String)
    case invalidModel(String)

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active session"
        case .unknownProvider(let id):
            return "Unknown provider: \(id)"
        case .noCredentials(let id):
            return "No API key configured for provider: \(id)"
        case .invalidModel(let id):
            return "Invalid model: \(id)"
        }
    }
}

import Foundation

// MARK: - CopilotBackedRuntime

/// Compatibility adapter that wraps the existing CopilotSession/CopilotAgent behind
/// the new AgentSessionRuntime protocol. This allows ChatViewModel to depend on
/// the new boundary while keeping the current Copilot-backed implementation working.
///
/// Phase 1: ChatViewModel uses AgentSessionRuntime instead of CopilotSession directly.
/// Phase 2: DirectProviderRuntime replaces this adapter.
public final class CopilotBackedRuntime: AgentSessionRuntime, @unchecked Sendable {

    // MARK: - State

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

    @MainActor private var _state: SessionState = .disconnected
    @MainActor private var _currentModel: ModelInfo?

    // MARK: - Internals

    private var client: CopilotClient?
    private var session: CopilotSession?
    private var agent: CopilotAgent?
    private let transport: Transport

    private let subscriptionLock = NSLock()
    private var subscriptions: [RuntimeSubscription: @Sendable (RuntimeEvent) -> Void] = [:]

    /// Access to the underlying session for features not yet covered by the runtime interface.
    public var underlyingSession: CopilotSession? { session }

    // MARK: - Init

    public init(transport: Transport, sessionId: String = UUID().uuidString) {
        self.transport = transport
        self.sessionId = sessionId
    }

    // MARK: - Session Lifecycle

    public func createSession(config: RuntimeSessionConfig) async throws {
        await MainActor.run { _state = .connecting }

        let client = CopilotClient(transport: transport)
        self.client = client
        try await client.start()

        var sessionConfig = SessionConfig()
        sessionConfig.model = config.model
        sessionConfig.systemMessage = config.systemMessage.map { .replace($0) }
        sessionConfig.tools = config.tools
        sessionConfig.workingDirectory = config.workingDirectory
        sessionConfig.streaming = config.streaming

        if let effort = config.reasoningEffort {
            sessionConfig.reasoningEffort = effort
        }

        let session = try await client.createSession(config: sessionConfig)
        self.session = session

        // Subscribe to session events and translate to RuntimeEvents
        await subscribeToSessionEvents(session: session)

        await MainActor.run { _state = .idle }
    }

    public func restoreSession(name: String) async throws {
        // Copilot relay doesn't support local restore; this is a no-op for the compatibility layer
        // Direct provider runtime will implement this via SessionStore
    }

    public func send(prompt: String, attachments: [RuntimeAttachment]?) async throws {
        guard let session else { throw RuntimeAdapterError.noActiveSession }
        await MainActor.run { _state = .working }
        _ = try await session.send(prompt: prompt)
    }

    public func steer(message: String) async throws {
        guard let session else { throw RuntimeAdapterError.noActiveSession }
        _ = try await session.send(prompt: message, mode: .immediate)
    }

    public func abort() async {
        // Copilot sessions don't have a clean abort; we can disconnect
        session = nil
        client?.disconnect()
        await MainActor.run { _state = .idle }
    }

    public func destroy() async {
        if let session {
            try? await session.destroy()
        }
        session = nil
        client?.disconnect()
        client = nil
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
        guard let session else { throw RuntimeAdapterError.noActiveSession }
        let result = responses.values.joined(separator: "\n")
        try await session.respondToExternalTool(requestId: requestId, result: result)
    }

    // MARK: - History

    public func getMessages() async throws -> [RuntimeMessage] {
        guard let session else { return [] }
        let events = try await session.getMessages()
        return events.compactMap { event -> RuntimeMessage? in
            switch event.type {
            case .userMessage:
                if case .object(let data) = event.data,
                   case .string(let content) = data["content"] {
                    return RuntimeMessage(role: .user, content: content,
                                         timestamp: event.timestamp.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date())
                }
            case .assistantMessage:
                if case .object(let data) = event.data,
                   case .string(let content) = data["content"] {
                    return RuntimeMessage(role: .assistant, content: content,
                                         timestamp: event.timestamp.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date())
                }
            default:
                break
            }
            return nil
        }
    }

    public func clearHistory() async throws {
        // Copilot relay sessions don't support clearing history
    }

    // MARK: - Event Bridge

    private func subscribeToSessionEvents(session: CopilotSession) async {
        // Subscribe to all event types and translate them
        await session.on { [weak self] event in
            guard let self else { return }
            if let runtimeEvent = RuntimeEvent.from(sessionEvent: event) {
                self.emit(runtimeEvent)

                // Update internal state based on events
                switch runtimeEvent {
                case .sessionIdle:
                    Task { @MainActor in self._state = .idle }
                case .turnStart:
                    Task { @MainActor in self._state = .working }
                case .compactionStart:
                    Task { @MainActor in self._state = .compacting }
                case .compactionComplete:
                    Task { @MainActor in self._state = .working }
                case .error(let err):
                    Task { @MainActor in self._state = .error(err.message) }
                case .userInputRequested:
                    Task { @MainActor in self._state = .waitingForUser }
                default:
                    break
                }
            }
        }
    }

    private func emit(_ event: RuntimeEvent) {
        subscriptionLock.lock()
        let handlers = Array(subscriptions.values)
        subscriptionLock.unlock()
        for handler in handlers {
            handler(event)
        }
    }
}

// MARK: - Errors

public enum RuntimeAdapterError: Error, LocalizedError {
    case noActiveSession

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active session"
        }
    }
}

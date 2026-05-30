import Foundation
#if canImport(os)
import os
#endif

/// Runtime that connects to a Neo desktop instance via the relay proxy.
/// Uses the relay's HTTP proxy for requests and SSE streaming for events.
///
/// API mapping:
///   - Send prompt: POST /api/neo/proxy/api/chat/send  { prompt: "..." }
///   - Abort:       POST /api/neo/proxy/api/chat/abort
///   - Sessions:    GET  /api/neo/proxy/api/sessions
///   - Events:      GET  /api/neo/stream/api/events     (SSE)
///   - Status:      GET  /api/neo/proxy/api/status
public final class NeoDesktopRuntime: AgentSessionRuntime, @unchecked Sendable {

    // MARK: - Properties

    public let sessionId: String = UUID().uuidString

    public var state: SessionState {
        get async { _state }
    }

    public var currentModel: ModelInfo? {
        get async { nil } // Neo decides the model
    }

    private var _state: SessionState = .disconnected
    private var _subscriptions: [RuntimeSubscription: @Sendable (RuntimeEvent) -> Void] = [:]
    private let lock = NSLock()

    private let relayBaseURL: String
    private let pairingSecret: String
    private var sseTask: Task<Void, Never>?

    /// Dedicated session for SSE with longer timeout (keeps connection alive)
    private lazy var sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 min — keepalives every 30s
        config.timeoutIntervalForResource = 0   // no resource timeout
        return URLSession(configuration: config)
    }()

    #if canImport(os)
    private let logger = Logger(subsystem: "com.neox.app", category: "NeoDesktopRuntime")
    #endif

    // MARK: - Init

    /// - Parameters:
    ///   - relayBaseURL: The relay server URL (e.g. "https://relay.ai.qili2.com")
    ///   - pairingSecret: The pairing secret from the pairing flow
    public init(relayBaseURL: String = "https://relay.ai.qili2.com", pairingSecret: String) {
        self.relayBaseURL = relayBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.pairingSecret = pairingSecret
    }

    // MARK: - Session Lifecycle

    public func createSession(config: RuntimeSessionConfig) async throws {
        updateState(.connecting)

        // Check if Neo is online
        let status = try await proxyGET("/api/neo/status")
        guard let online = status["online"] as? Bool, online else {
            updateState(.error("Neo desktop is offline"))
            throw NeoDesktopError.neoOffline
        }

        // Start SSE subscription
        startSSEStream()
        updateState(.idle)
    }

    public func restoreSession(name: String) async throws {
        // Neo manages sessions — just reconnect SSE
        try await createSession(config: RuntimeSessionConfig(sessionName: name))
    }

    public func send(prompt: String, attachments: [RuntimeAttachment]?) async throws {
        updateState(.working)
        emit(.turnStart(.init()))

        do {
            // Check for audio attachments — send via audio transcription endpoint
            if let audio = attachments?.first(where: { $0.mimeType.hasPrefix("audio/") }) {
                let base64 = audio.data.base64EncodedString()
                let ext = audio.name.components(separatedBy: ".").last ?? "m4a"
                var body: [String: Any] = ["audio": base64, "format": ext]
                if !prompt.isEmpty { body["language"] = prompt } // Use prompt text as language hint if short
                let _ = try await proxyPOST("/api/neo/proxy/api/chat/send-audio", body: body)
            } else {
                var body: [String: Any] = ["prompt": prompt]
                // Include image + video attachments as base64
                if let atts = attachments, !atts.isEmpty {
                    let media = atts.filter { $0.isMedia }.map { att -> [String: String] in
                        ["name": att.name, "data": att.data.base64EncodedString(), "mimeType": att.mimeType]
                    }
                    if !media.isEmpty { body["attachments"] = media }
                }
                let _ = try await proxyPOST("/api/neo/proxy/api/chat/send", body: body)
            }
            // Response is just { ok: true } — actual content comes via SSE events
        } catch {
            updateState(.error(error.localizedDescription))
            emit(.error(.init(message: error.localizedDescription)))
            throw error
        }
    }

    public func steer(message: String) async throws {
        let body: [String: Any] = ["message": message]
        let _ = try await proxyPOST("/api/neo/proxy/api/chat/steer", body: body)
    }

    public func abort() async {
        let _ = try? await proxyPOST("/api/neo/proxy/api/chat/abort", body: [:])
        updateState(.idle)
    }

    /// Set the askChannel preference on the Neo desktop.
    /// - Parameter channel: "neox", "auto", "ui", "discord", "wechat"
    public func setAskChannel(_ channel: String) async throws {
        let _ = try await proxyPOST("/api/neo/proxy/api/settings", body: ["askChannel": channel])
    }

    /// Get the current askChannel preference from the Neo desktop.
    public func getAskChannel() async throws -> String {
        let settings = try await proxyGET("/api/neo/proxy/api/settings")
        return settings["askChannel"] as? String ?? "auto"
    }

    public func destroy() async {
        sseTask?.cancel()
        sseTask = nil
        updateState(.disconnected)
    }

    // MARK: - Event Subscription

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (RuntimeEvent) -> Void) -> RuntimeSubscription {
        let sub = RuntimeSubscription()
        lock.lock()
        _subscriptions[sub] = handler
        lock.unlock()
        return sub
    }

    public func unsubscribe(_ subscription: RuntimeSubscription) {
        lock.lock()
        _subscriptions.removeValue(forKey: subscription)
        lock.unlock()
    }

    // MARK: - User Input

    public func respondToUserInput(requestId: String, responses: [String: String]) async throws {
        // Neo's /api/chat/answer-questions expects { answers: { header: { selected: [], freeText: "..." } } }
        var answers: [String: Any] = [:]
        for (key, value) in responses {
            answers[key] = ["selected": [String](), "freeText": value]
        }
        let body: [String: Any] = ["answers": answers]
        let _ = try await proxyPOST("/api/neo/proxy/api/chat/answer-questions", body: body)
    }

    // MARK: - History

    public func getMessages() async throws -> [RuntimeMessage] {
        let data = try await proxyGET("/api/neo/proxy/api/sessions/messages")
        guard let messages = data["messages"] as? [[String: Any]] else {
            return []
        }
        return messages.compactMap { msg in
            guard let role = msg["role"] as? String,
                  let content = msg["content"] as? String else { return nil }
            let rtRole: RuntimeMessage.Role
            switch role {
            case "user": rtRole = .user
            case "assistant": rtRole = .assistant
            case "tool", "toolResult": rtRole = .tool
            case "system": rtRole = .system
            default: rtRole = .assistant
            }
            return RuntimeMessage(
                role: rtRole,
                content: content,
                model: msg["model"] as? String,
                thinking: msg["thinking"] as? String
            )
        }
    }

    public func clearHistory() async throws {
        // Neo doesn't have a clear-current-session API, so create a new session
        let _ = try await proxyPOST("/api/neo/proxy/api/sessions/create", body: [:])
    }

    // MARK: - SSE Streaming

    private func startSSEStream() {
        sseTask?.cancel()
        sseTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runSSELoop()
        }
    }

    private func runSSELoop() async {
        let urlString = "\(relayBaseURL)/api/neo/stream/api/events"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(pairingSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300  // 5 min

        #if canImport(os)
        logger.info("SSE connecting to \(urlString)")
        #endif

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = SSEDataDelegate(runtime: self) {
                continuation.resume()
            }
            self._sseDelegate = delegate
            let task = sseSession.dataTask(with: request)
            task.delegate = delegate
            task.resume()
        }

        // Stream ended — reconnect
        if !Task.isCancelled {
            #if canImport(os)
            logger.info("SSE stream ended, reconnecting in 3s...")
            #endif
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                await runSSELoop()
            }
        }
    }

    private var _sseDelegate: SSEDataDelegate?

    // MARK: - SSE Event Parsing

    fileprivate func handleSSEEvent(event: String, data: String) {
        switch event {
        case "delta":
            // Skip text deltas — wait for the complete `message` event so the chat
            // bubble shows clean text (some providers/relays double-encode deltas,
            // producing `""word""` artifacts when concatenated).
            if _state == .waitingForUser {
                updateState(.working)
            }
            break

        case "thinking":
            // If we were waiting for user input but got thinking, the question was answered elsewhere
            if _state == .waitingForUser {
                updateState(.working)
            }
            // Reasoning delta (data is JSON-encoded string)
            let text = (try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? String) ?? data
            emit(.reasoningDelta(.init(text: text)))

        case "message":
            // Complete message — parse JSON
            guard let json = parseJSON(data) else { return }
            let role = json["role"] as? String ?? ""
            let content = json["content"] as? String ?? ""

            switch role {
            case "assistant":
                let thinking = json["thinking"] as? String
                emit(.assistantMessageComplete(.init(
                    content: content,
                    model: json["model"] as? String
                )))
                if let thinking = thinking, !thinking.isEmpty {
                    emit(.reasoningComplete(.init(content: thinking)))
                }
            case "user":
                // User echo — ignore (UI already shows user message)
                break
            case "toolResult":
                // Tool result
                let toolName = json["toolName"] as? String ?? "unknown"
                emit(.toolComplete(.init(
                    toolCallId: UUID().uuidString,
                    toolName: toolName,
                    result: content,
                    isError: false
                )))
            default:
                break
            }

        case "tool-start":
            guard let json = parseJSON(data) else { return }
            let toolName = json["toolName"] as? String ?? "unknown"
            let args = json["args"] as? [String: Any]
            emit(.toolStart(.init(
                toolCallId: UUID().uuidString,
                toolName: toolName,
                arguments: args.flatMap { try? String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8) }
            )))
            // Surface routing/assignment intent inline as a chat bubble (mirrors discord-bridge)
            if toolName == "route_to_agent", let agent = (args?["agent"] as? String) {
                let task = (args?["task"] as? String) ?? ""
                let suffix = task.isEmpty ? "" : ": \(String(task.prefix(300)))"
                emit(.assistantMessageComplete(.init(content: "🚀 Route → \(agent)\(suffix)", model: nil)))
            } else if toolName == "assign_task", let pid = (args?["projectId"] as? String) {
                let prompt = (args?["prompt"] as? String) ?? ""
                let suffix = prompt.isEmpty ? "" : ": \(String(prompt.prefix(300)))"
                emit(.assistantMessageComplete(.init(content: "📋 Assign → \(pid)\(suffix)", model: nil)))
            }

        case "terminal-start":
            guard let json = parseJSON(data) else { return }
            if let explanation = json["explanation"] as? String, !explanation.isEmpty {
                emit(.assistantMessageComplete(.init(content: "⚙️ \(explanation)", model: nil)))
            }

        case "tool-end":
            guard let json = parseJSON(data) else { return }
            let toolName = json["toolName"] as? String ?? "unknown"
            emit(.toolComplete(.init(
                toolCallId: UUID().uuidString,
                toolName: toolName,
                result: nil,
                isError: false
            )))

        case "idle":
            updateState(.idle)
            emit(.turnEnd(.init()))
            emit(.sessionIdle)

        case "questions":
            // User input requested
            guard let questions = parseJSONArray(data) else { return }
            let requestId = UUID().uuidString
            let rtQuestions = questions.compactMap { q -> RuntimeEvent.UserInputRequest.Question? in
                guard let header = q["header"] as? String,
                      let question = q["question"] as? String else { return nil }
                let options = (q["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String }
                return .init(
                    id: header,
                    text: question,
                    options: options,
                    multiSelect: q["multiSelect"] as? Bool ?? false
                )
            }
            if !rtQuestions.isEmpty {
                updateState(.waitingForUser)
                emit(.userInputRequested(.init(requestId: requestId, questions: rtQuestions)))
            }

        case "usage-update":
            guard let json = parseJSON(data) else { return }
            let cost = json["costUsd"] as? Double ?? 0
            emit(.usageUpdate(.init(
                model: "neo-desktop",
                promptTokens: 0,
                completionTokens: 0,
                cost: cost
            )))

        case "session-renamed":
            // Could trigger a UI refresh, but not critical
            break

        case "session-cleared":
            break

        case "connected":
            // SSE connected — Neo is ready. If we were stuck in .working from
            // a prior turn that lost events (relay restart), reset to .idle.
            if _state == .working {
                updateState(.idle)
                emit(.turnEnd(.init()))
                emit(.sessionIdle)
            }
            #if canImport(os)
            logger.info("SSE connected to Neo")
            #endif

        default:
            break
        }
    }

    // MARK: - HTTP Helpers

    private func proxyGET(_ path: String) async throws -> [String: Any] {
        let url = URL(string: "\(relayBaseURL)\(path)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(pairingSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NeoDesktopError.invalidResponse
        }
        if http.statusCode >= 400 {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = body?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw NeoDesktopError.serverError(msg)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func proxyPOST(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "\(relayBaseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairingSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NeoDesktopError.invalidResponse
        }
        if http.statusCode >= 400 {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = body?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw NeoDesktopError.serverError(msg)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - State & Events

    private func updateState(_ newState: SessionState) {
        _state = newState
    }

    private func emit(_ event: RuntimeEvent) {
        lock.lock()
        let handlers = Array(_subscriptions.values)
        lock.unlock()
        for handler in handlers {
            handler(event)
        }
    }

    // MARK: - JSON Parsing Helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func parseJSONArray(_ string: String) -> [[String: Any]]? {
        guard let data = string.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr
    }
}

// MARK: - Errors

public enum NeoDesktopError: LocalizedError {
    case neoOffline
    case invalidResponse
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .neoOffline: return "Neo desktop is not connected"
        case .invalidResponse: return "Invalid response from relay"
        case .serverError(let msg): return msg
        }
    }
}

// MARK: - SSE Data Delegate (delegate-based streaming for reliable SSE on iOS)

private final class SSEDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var runtime: NeoDesktopRuntime?
    private let onComplete: () -> Void
    private var buffer = ""
    private var currentEvent = "message"
    private var dataLines: [String] = []

    #if canImport(os)
    private let logger = Logger(subsystem: "com.neox.app", category: "SSEDelegate")
    #endif

    init(runtime: NeoDesktopRuntime, onComplete: @escaping () -> Void) {
        self.runtime = runtime
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            #if canImport(os)
            logger.error("SSE HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            #endif
            completionHandler(.cancel)
            onComplete()
            return
        }
        #if canImport(os)
        logger.info("SSE connected, HTTP 200")
        #endif
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        #if canImport(os)
        logger.info("SSE chunk: \(chunk.prefix(100))")
        #endif
        buffer += chunk
        processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        #if canImport(os)
        if let error = error {
            logger.error("SSE completed with error: \(error.localizedDescription)")
        } else {
            logger.info("SSE completed normally")
        }
        #endif
        onComplete()
    }

    private func processBuffer() {
        // Split buffer into lines, keeping partial line in buffer
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])

            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataLines.append(String(line.dropFirst(6)))
            } else if line.isEmpty && !dataLines.isEmpty {
                // End of SSE event — dispatch
                let data = dataLines.joined(separator: "\n")
                dataLines.removeAll()
                let event = currentEvent
                currentEvent = "message"
                runtime?.handleSSEEvent(event: event, data: data)
            } else if line.hasPrefix(":") {
                // Comment / keepalive — ignore
            }
        }
    }
}

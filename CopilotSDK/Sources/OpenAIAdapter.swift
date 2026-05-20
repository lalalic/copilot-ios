import Foundation
import os

// MARK: - OpenAIAdapter

/// Provider adapter for OpenAI-compatible APIs (OpenAI, Azure, Ollama, vLLM, etc.).
/// Supports the Chat Completions API with streaming via Server-Sent Events.
public final class OpenAIAdapter: ProviderAdapter, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.copilot-ios", category: "OpenAIAdapter")

    public let providerId: String
    public let displayName: String

    private let defaultBaseURL: String
    private var currentTask: Task<Void, Never>?
    private let usageCalculator: UsageCalculator?

    public init(
        providerId: String = "openai",
        displayName: String = "OpenAI",
        defaultBaseURL: String = "https://api.openai.com/v1",
        usageCalculator: UsageCalculator? = nil
    ) {
        self.providerId = providerId
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.usageCalculator = usageCalculator
    }

    // MARK: - ProviderAdapter

    public func listModels() async throws -> [ModelInfo] {
        // Return models from the registry; actual API listing can be added later
        return []
    }

    public func streamCompletion(
        messages: [ProviderMessage],
        model: String,
        systemMessage: String?,
        tools: [ProviderToolDefinition],
        config: ProviderRequestConfig,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws {
        let baseURL = config.baseURL ?? defaultBaseURL
        let url = URL(string: "\(baseURL)/chat/completions")!

        // Build request body
        var body: [String: Any] = [
            "model": model,
            "stream": config.streaming,
        ]

        if config.streaming {
            body["stream_options"] = ["include_usage": true]
        }

        if let maxTokens = config.maxTokens {
            body["max_tokens"] = maxTokens
        }
        if let temperature = config.temperature {
            body["temperature"] = temperature
        }
        if let reasoningEffort = config.reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }

        // Build messages array
        var apiMessages: [[String: Any]] = []

        if let systemMessage {
            apiMessages.append(["role": "system", "content": systemMessage])
        }

        for msg in messages {
            apiMessages.append(buildAPIMessage(from: msg))
        }
        body["messages"] = apiMessages

        // Add tools if present
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersSchema,
                    ] as [String: Any],
                ]
            }
        }

        // Build HTTP request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        config.customHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData

        Self.logger.info("[OAI] request to \(url.absoluteString) model=\(model) bodySize=\(jsonData.count) streaming=\(config.streaming)")

        if config.streaming {
            try await streamSSE(request: request, model: model, onEvent: onEvent)
        } else {
            try await nonStreamingRequest(request: request, model: model, onEvent: onEvent)
        }
    }

    public func abort() async {
        currentTask?.cancel()
        currentTask = nil
    }

    public func validateCredentials(apiKey: String, baseURL: String?) async throws -> Bool {
        let base = baseURL ?? defaultBaseURL
        let url = URL(string: "\(base)/models")!

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    // MARK: - Streaming

    private func streamSSE(
        request: URLRequest,
        model: String,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws {
        Self.logger.info("[SSE] starting request")
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.error("[SSE] invalid response (not HTTP)")
            throw OpenAIAdapterError.invalidResponse
        }

        Self.logger.info("[SSE] status=\(httpResponse.statusCode)")

        Self.publishWalletHeader(httpResponse)

        // Server-side wallet (relay v4): 402 → insufficient_funds.
        if httpResponse.statusCode == 402 {
            var bodyText = ""
            for try await line in asyncBytes.lines { bodyText += line }
            Self.logger.warning("[SSE] insufficient_funds: \(bodyText.prefix(200))")
            throw OpenAIAdapterError.apiError(statusCode: 402, message: bodyText)
        }

        guard httpResponse.statusCode == 200 else {
            // Read error body
            var errorBody = ""
            for try await line in asyncBytes.lines {
                errorBody += line
            }
            Self.logger.error("[SSE] API error: \(httpResponse.statusCode) \(errorBody.prefix(200))")
            throw OpenAIAdapterError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        onEvent(.turnStart(.init()))

        var accumulatedToolCalls: [String: AccumulatedToolCall] = [:]

        for try await line in asyncBytes.lines {
            guard !Task.isCancelled else { break }

            guard line.hasPrefix("data: ") else { continue }
            let data = String(line.dropFirst(6))
            guard data != "[DONE]" else { break }
            guard let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                // Check for usage in the final chunk
                if let usage = json["usage"] as? [String: Any] {
                    emitUsage(usage: usage, model: model, onEvent: onEvent)
                }
                continue
            }

            if let delta = choice["delta"] as? [String: Any] {
                // Text content
                if let content = delta["content"] as? String {
                    onEvent(.assistantTextDelta(.init(text: content)))
                }

                // Reasoning / thinking (OpenAI o-series)
                if let reasoning = delta["reasoning_content"] as? String {
                    onEvent(.reasoningDelta(.init(text: reasoning)))
                }

                // Tool calls
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        guard let index = tc["index"] as? Int else { continue }
                        let key = "\(index)"

                        if let id = tc["id"] as? String,
                           let function = tc["function"] as? [String: Any],
                           let name = function["name"] as? String {
                            // New tool call
                            accumulatedToolCalls[key] = AccumulatedToolCall(
                                id: id,
                                name: name,
                                arguments: (function["arguments"] as? String) ?? ""
                            )
                            onEvent(.toolStart(.init(toolCallId: id, toolName: name)))
                        } else if let function = tc["function"] as? [String: Any],
                                  let argChunk = function["arguments"] as? String {
                            // Argument delta
                            accumulatedToolCalls[key]?.arguments += argChunk
                        }
                    }
                }
            }

            // Check finish reason
            if let finishReason = choice["finish_reason"] as? String {
                if finishReason == "tool_calls" {
                    // Emit completed tool calls with accumulated arguments
                    for (_, tc) in accumulatedToolCalls {
                        onEvent(.toolComplete(.init(
                            toolCallId: tc.id,
                            toolName: tc.name,
                            result: tc.arguments
                        )))
                    }
                }
            }

            // Usage in streaming chunks (when stream_options.include_usage is set)
            if let usage = json["usage"] as? [String: Any] {
                emitUsage(usage: usage, model: model, onEvent: onEvent)
            }
        }

        onEvent(.turnEnd(.init()))
        onEvent(.sessionIdle)
    }

    // MARK: - Non-Streaming

    private func nonStreamingRequest(
        request: URLRequest,
        model: String,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAdapterError.invalidResponse
        }

        Self.publishWalletHeader(httpResponse)

        if httpResponse.statusCode == 402 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            Self.logger.warning("[OAI] insufficient_funds: \(bodyText.prefix(200))")
            throw OpenAIAdapterError.apiError(statusCode: 402, message: bodyText)
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAIAdapterError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw OpenAIAdapterError.invalidResponse
        }

        onEvent(.turnStart(.init()))

        if let content = message["content"] as? String {
            onEvent(.assistantMessageComplete(.init(content: content, model: model)))
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let id = tc["id"] as? String,
                      let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let args = (function["arguments"] as? String) ?? "{}"
                onEvent(.toolStart(.init(toolCallId: id, toolName: name, arguments: args)))
                onEvent(.toolComplete(.init(toolCallId: id, toolName: name, result: args)))
            }
        }

        if let usage = json["usage"] as? [String: Any] {
            emitUsage(usage: usage, model: model, onEvent: onEvent)
        }

        onEvent(.turnEnd(.init()))
        onEvent(.sessionIdle)
    }

    // MARK: - Helpers

    private func buildAPIMessage(from msg: ProviderMessage) -> [String: Any] {
        var apiMsg: [String: Any] = ["role": msg.role.rawValue]

        // Handle tool results
        if msg.role == .tool {
            if let toolCallId = msg.toolCallId {
                apiMsg["tool_call_id"] = toolCallId
            }
            // Tool messages: support multimodal content (images from describe_media)
            let hasImages = msg.content.contains { if case .image = $0 { return true } else { return false } }
            if hasImages {
                var contentParts: [[String: Any]] = []
                for part in msg.content {
                    switch part {
                    case .text(let s):
                        contentParts.append(["type": "text", "text": s])
                    case .image(let data, let mimeType):
                        let base64 = data.base64EncodedString()
                        contentParts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mimeType);base64,\(base64)"],
                        ])
                    }
                }
                apiMsg["content"] = contentParts
            } else {
                let textContent = msg.content.compactMap { part -> String? in
                    if case .text(let s) = part { return s }
                    return nil
                }.joined()
                apiMsg["content"] = textContent
            }
            return apiMsg
        }

        // Handle multimodal content
        let hasImages = msg.content.contains { if case .image = $0 { return true } else { return false } }

        if hasImages {
            var contentParts: [[String: Any]] = []
            for part in msg.content {
                switch part {
                case .text(let s):
                    contentParts.append(["type": "text", "text": s])
                case .image(let data, let mimeType):
                    let base64 = data.base64EncodedString()
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mimeType);base64,\(base64)"],
                    ])
                }
            }
            apiMsg["content"] = contentParts
        } else {
            let textContent = msg.content.compactMap { part -> String? in
                if case .text(let s) = part { return s }
                return nil
            }.joined()
            apiMsg["content"] = textContent
        }

        // Handle tool calls in assistant messages
        if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
            apiMsg["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                [
                    "id": tc.id,
                    "type": "function",
                    "function": [
                        "name": tc.name,
                        "arguments": tc.arguments,
                    ] as [String: Any],
                ]
            }
        }

        // Include reasoning_content for DeepSeek thinking mode
        if let reasoning = msg.reasoningContent {
            apiMsg["reasoning_content"] = reasoning
        }

        return apiMsg
    }

    private func emitUsage(usage: [String: Any], model: String, onEvent: @escaping @Sendable (RuntimeEvent) -> Void) {
        let promptTokens = usage["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage["completion_tokens"] as? Int ?? 0

        if let calc = usageCalculator {
            let event = calc.createUsageEvent(
                provider: providerId,
                modelId: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
            onEvent(.usageUpdate(event))
        } else {
            onEvent(.usageUpdate(.init(
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cost: 0
            )))
        }
    }

    /// Accumulated tool call state during streaming.
    private struct AccumulatedToolCall {
        let id: String
        let name: String
        var arguments: String
    }

    // MARK: - Server-side wallet (relay v4)

    /// Posted whenever the relay returns an `X-Balance-Cents` header.
    /// `userInfo["cents"]` is the integer balance in cents.
    /// Observers (e.g. a `BalanceStore`) can mirror it into UI state.
    public static let walletBalanceDidChange = Notification.Name("CopilotSDK.WalletBalanceDidChange")

    /// Read `X-Balance-Cents` from the response (relay v4 server-side wallet)
    /// and broadcast it. Best-effort — silent on missing/invalid header.
    static func publishWalletHeader(_ response: HTTPURLResponse) {
        guard let raw = response.value(forHTTPHeaderField: "X-Balance-Cents") ?? response.value(forHTTPHeaderField: "x-balance-cents"),
              let cents = Int(raw.trimmingCharacters(in: .whitespaces))
        else { return }
        NotificationCenter.default.post(
            name: walletBalanceDidChange,
            object: nil,
            userInfo: ["cents": cents]
        )
    }
}

// MARK: - Errors

public enum OpenAIAdapterError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from OpenAI API"
        case .apiError(let code, let message):
            return "OpenAI API error (\(code)): \(message)"
        }
    }
}

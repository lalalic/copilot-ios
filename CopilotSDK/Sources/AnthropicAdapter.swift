import Foundation

// MARK: - AnthropicAdapter

/// Provider adapter for Anthropic's Messages API.
/// Supports streaming via Server-Sent Events with content block deltas.
public final class AnthropicAdapter: ProviderAdapter, @unchecked Sendable {

    public let providerId: String
    public let displayName: String

    private let defaultBaseURL: String
    private var currentTask: Task<Void, Never>?
    private let usageCalculator: UsageCalculator?
    private let apiVersion: String

    public init(
        providerId: String = "anthropic",
        displayName: String = "Anthropic",
        defaultBaseURL: String = "https://api.anthropic.com/v1",
        apiVersion: String = "2023-06-01",
        usageCalculator: UsageCalculator? = nil
    ) {
        self.providerId = providerId
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.apiVersion = apiVersion
        self.usageCalculator = usageCalculator
    }

    // MARK: - ProviderAdapter

    public func listModels() async throws -> [ModelInfo] {
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
        let url = URL(string: "\(baseURL)/messages")!

        // Build request body
        var body: [String: Any] = [
            "model": model,
            "stream": config.streaming,
            "max_tokens": config.maxTokens ?? 8192,
        ]

        if let systemMessage {
            body["system"] = systemMessage
        }
        if let temperature = config.temperature {
            body["temperature"] = temperature
        }

        // Anthropic extended thinking support
        if let reasoningEffort = config.reasoningEffort {
            let budgetTokens: Int
            switch reasoningEffort {
            case "low": budgetTokens = 4096
            case "medium": budgetTokens = 16384
            case "high": budgetTokens = 65536
            default: budgetTokens = 16384
            }
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": budgetTokens,
            ] as [String: Any]
        }

        // Build messages array — Anthropic format
        var apiMessages: [[String: Any]] = []
        for msg in messages {
            if msg.role == .system { continue }  // System handled separately
            apiMessages.append(buildAPIMessage(from: msg))
        }
        body["messages"] = apiMessages

        // Add tools if present
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parametersSchema,
                ]
            }
        }

        // Build HTTP request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        config.customHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData

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
        let url = URL(string: "\(base)/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10

        // Send a minimal request to validate the key
        let body: [String: Any] = [
            "model": "claude-3-5-haiku-20241022",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        // 200 = success, 401 = bad key
        return httpResponse.statusCode == 200
    }

    // MARK: - Streaming

    private func streamSSE(
        request: URLRequest,
        model: String,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAdapterError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in asyncBytes.lines {
                errorBody += line
            }
            throw AnthropicAdapterError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        var currentEventType = ""
        var inputTokens = 0
        var outputTokens = 0
        var currentToolCall: (id: String, name: String, arguments: String)?

        for try await line in asyncBytes.lines {
            guard !Task.isCancelled else { break }

            if line.hasPrefix("event: ") {
                currentEventType = String(line.dropFirst(7))
                continue
            }

            guard line.hasPrefix("data: ") else { continue }
            let dataStr = String(line.dropFirst(6))
            guard let jsonData = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            switch currentEventType {
            case "message_start":
                onEvent(.turnStart(.init()))
                // Extract input tokens from message.usage
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                }

            case "content_block_start":
                if let contentBlock = json["content_block"] as? [String: Any],
                   let type = contentBlock["type"] as? String {
                    if type == "tool_use" {
                        let id = contentBlock["id"] as? String ?? UUID().uuidString
                        let name = contentBlock["name"] as? String ?? "unknown"
                        currentToolCall = (id: id, name: name, arguments: "")
                        onEvent(.toolStart(.init(toolCallId: id, toolName: name)))
                    }
                }

            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   let type = delta["type"] as? String {
                    switch type {
                    case "text_delta":
                        if let text = delta["text"] as? String {
                            onEvent(.assistantTextDelta(.init(text: text)))
                        }

                    case "thinking_delta":
                        if let thinking = delta["thinking"] as? String {
                            onEvent(.reasoningDelta(.init(text: thinking)))
                        }

                    case "input_json_delta":
                        if let partial = delta["partial_json"] as? String {
                            currentToolCall?.arguments += partial
                        }

                    default:
                        break
                    }
                }

            case "content_block_stop":
                // Finalize current tool call
                if let tc = currentToolCall {
                    onEvent(.toolComplete(.init(
                        toolCallId: tc.id,
                        toolName: tc.name,
                        result: tc.arguments
                    )))
                    currentToolCall = nil
                }

            case "message_delta":
                if let usage = json["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }

            case "message_stop":
                // Emit usage
                if inputTokens > 0 || outputTokens > 0 {
                    if let calc = usageCalculator {
                        let event = calc.createUsageEvent(
                            provider: providerId,
                            modelId: model,
                            promptTokens: inputTokens,
                            completionTokens: outputTokens
                        )
                        onEvent(.usageUpdate(event))
                    } else {
                        onEvent(.usageUpdate(.init(
                            model: model,
                            promptTokens: inputTokens,
                            completionTokens: outputTokens,
                            cost: 0
                        )))
                    }
                }
                onEvent(.turnEnd(.init()))
                onEvent(.sessionIdle)

            case "error":
                let errorMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                onEvent(.error(.init(message: errorMsg)))

            default:
                break
            }
        }
    }

    // MARK: - Non-Streaming

    private func nonStreamingRequest(
        request: URLRequest,
        model: String,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void
    ) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAdapterError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AnthropicAdapterError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicAdapterError.invalidResponse
        }

        onEvent(.turnStart(.init()))

        // Parse content blocks
        if let content = json["content"] as? [[String: Any]] {
            for block in content {
                guard let type = block["type"] as? String else { continue }
                switch type {
                case "text":
                    if let text = block["text"] as? String {
                        onEvent(.assistantMessageComplete(.init(content: text, model: model)))
                    }

                case "thinking":
                    if let thinking = block["thinking"] as? String {
                        onEvent(.reasoningComplete(.init(content: thinking)))
                    }

                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "unknown"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let argsData = try? JSONSerialization.data(withJSONObject: input)
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    onEvent(.toolStart(.init(toolCallId: id, toolName: name, arguments: argsString)))
                    onEvent(.toolComplete(.init(toolCallId: id, toolName: name, result: argsString)))

                default:
                    break
                }
            }
        }

        // Usage
        if let usage = json["usage"] as? [String: Any] {
            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
            if let calc = usageCalculator {
                let event = calc.createUsageEvent(
                    provider: providerId,
                    modelId: model,
                    promptTokens: inputTokens,
                    completionTokens: outputTokens
                )
                onEvent(.usageUpdate(event))
            } else {
                onEvent(.usageUpdate(.init(
                    model: model,
                    promptTokens: inputTokens,
                    completionTokens: outputTokens,
                    cost: 0
                )))
            }
        }

        onEvent(.turnEnd(.init()))
        onEvent(.sessionIdle)
    }

    // MARK: - Helpers

    private func buildAPIMessage(from msg: ProviderMessage) -> [String: Any] {
        var apiMsg: [String: Any] = ["role": msg.role.rawValue]

        // Handle tool results — Anthropic format
        if msg.role == .tool {
            apiMsg["role"] = "user"
            // Support multimodal tool results (images from describe_media)
            let hasImages = msg.content.contains { if case .image = $0 { return true } else { return false } }
            var resultContent: [[String: Any]] = []
            if hasImages {
                for part in msg.content {
                    switch part {
                    case .text(let s):
                        resultContent.append(["type": "text", "text": s])
                    case .image(let data, let mimeType):
                        let base64 = data.base64EncodedString()
                        resultContent.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mimeType,
                                "data": base64,
                            ] as [String: Any],
                        ])
                    }
                }
            } else {
                let textContent = msg.content.compactMap { part -> String? in
                    if case .text(let s) = part { return s }
                    return nil
                }.joined()
                resultContent.append(["type": "text", "text": textContent])
            }
            apiMsg["content"] = [[
                "type": "tool_result",
                "tool_use_id": msg.toolCallId ?? "",
                "content": resultContent,
            ] as [String: Any]]
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
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mimeType,
                            "data": base64,
                        ] as [String: Any],
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

        // Handle assistant messages with tool calls
        if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
            var contentParts: [[String: Any]] = []
            // Add text content first
            let textContent = msg.content.compactMap { part -> String? in
                if case .text(let s) = part { return s }
                return nil
            }.joined()
            if !textContent.isEmpty {
                contentParts.append(["type": "text", "text": textContent])
            }
            // Add tool use blocks
            for tc in toolCalls {
                let input = (try? JSONSerialization.jsonObject(with: Data(tc.arguments.utf8))) ?? [:]
                contentParts.append([
                    "type": "tool_use",
                    "id": tc.id,
                    "name": tc.name,
                    "input": input,
                ])
            }
            apiMsg["content"] = contentParts
        }

        return apiMsg
    }
}

// MARK: - Errors

public enum AnthropicAdapterError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Anthropic API"
        case .apiError(let code, let message):
            return "Anthropic API error (\(code)): \(message)"
        }
    }
}

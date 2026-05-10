import Testing
import Foundation
@testable import CopilotSDK

// MARK: - RuntimeEvent Tests

@Suite("RuntimeEvent")
struct RuntimeEventTests {

    @Test("map assistantMessageDelta SessionEvent to RuntimeEvent")
    func mapAssistantMessageDelta() {
        let sessionEvent = SessionEvent(
            type: .assistantMessageDelta,
            data: .object(["delta": .string("Hello ")])
        )
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .assistantTextDelta(let delta) = runtimeEvent else {
            Issue.record("Expected assistantTextDelta")
            return
        }
        #expect(delta.text == "Hello ")
    }

    @Test("map assistantMessage SessionEvent to RuntimeEvent")
    func mapAssistantMessage() {
        let sessionEvent = SessionEvent(
            type: .assistantMessage,
            data: .object(["content": .string("Hello world")])
        )
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .assistantMessageComplete(let msg) = runtimeEvent else {
            Issue.record("Expected assistantMessageComplete")
            return
        }
        #expect(msg.content == "Hello world")
    }

    @Test("map sessionIdle to sessionIdle")
    func mapSessionIdle() {
        let sessionEvent = SessionEvent(type: .sessionIdle, data: .null)
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .sessionIdle = runtimeEvent else {
            Issue.record("Expected sessionIdle")
            return
        }
    }

    @Test("map toolExecutionStart to toolStart")
    func mapToolStart() {
        let sessionEvent = SessionEvent(
            type: .toolExecutionStart,
            data: .object([
                "toolName": .string("read_file"),
                "toolCallId": .string("tc_1"),
                "arguments": .string("{\"path\":\"/tmp/test\"}")
            ])
        )
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .toolStart(let ts) = runtimeEvent else {
            Issue.record("Expected toolStart")
            return
        }
        #expect(ts.toolName == "read_file")
        #expect(ts.toolCallId == "tc_1")
    }

    @Test("map toolExecutionComplete to toolComplete")
    func mapToolComplete() {
        let sessionEvent = SessionEvent(
            type: .toolExecutionComplete,
            data: .object([
                "toolCallId": .string("tc_1"),
                "toolName": .string("read_file"),
                "result": .string("file contents"),
                "isError": .bool(false)
            ])
        )
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .toolComplete(let tc) = runtimeEvent else {
            Issue.record("Expected toolComplete")
            return
        }
        #expect(tc.toolCallId == "tc_1")
        #expect(tc.result == "file contents")
        #expect(tc.isError == false)
    }

    @Test("map assistantUsage to usageUpdate")
    func mapUsage() {
        let sessionEvent = SessionEvent(
            type: .assistantUsage,
            data: .object([
                "model": .string("gpt-4o"),
                "cost": .double(0.005),
                "inputTokens": .int(1000),
                "outputTokens": .int(500)
            ])
        )
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .usageUpdate(let usage) = runtimeEvent else {
            Issue.record("Expected usageUpdate")
            return
        }
        #expect(usage.model == "gpt-4o")
        #expect(usage.cost == 0.005)
        #expect(usage.promptTokens == 1000)
        #expect(usage.completionTokens == 500)
    }

    @Test("map sessionError to error")
    func mapError() {
        let sessionEvent = SessionEvent(
            type: .sessionError,
            data: .object(["message": .string("Rate limit exceeded")])
        )
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .error(let err) = runtimeEvent else {
            Issue.record("Expected error")
            return
        }
        #expect(err.message == "Rate limit exceeded")
    }

    @Test("map reasoningDelta")
    func mapReasoningDelta() {
        let sessionEvent = SessionEvent(
            type: .assistantReasoningDelta,
            data: .object(["delta": .string("thinking...")])
        )
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        guard case .reasoningDelta(let rd) = runtimeEvent else {
            Issue.record("Expected reasoningDelta")
            return
        }
        #expect(rd.text == "thinking...")
    }

    @Test("map compaction events")
    func mapCompaction() {
        let start = RuntimeEvent.from(sessionEvent: SessionEvent(type: .sessionCompactionStart, data: .null))
        guard case .compactionStart = start else {
            Issue.record("Expected compactionStart")
            return
        }

        let complete = RuntimeEvent.from(sessionEvent: SessionEvent(type: .sessionCompactionComplete, data: .null))
        guard case .compactionComplete = complete else {
            Issue.record("Expected compactionComplete")
            return
        }
    }

    @Test("unknown event type returns nil")
    func unknownEvent() {
        let sessionEvent = SessionEvent(type: .commandQueued, data: .null)
        let runtimeEvent = RuntimeEvent.from(sessionEvent: sessionEvent)
        #expect(runtimeEvent == nil)
    }
}

// MARK: - DirectProviderRuntime Defaults

@Suite("DirectProviderRuntime defaults")
struct DirectProviderRuntimeDefaultsTests {

    @Test("registers relay adapter alongside built-ins")
    func registersRelayAdapter() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpr-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let creds = CredentialStore()
        let registry = ModelRegistry()
        let store = SessionStore(storageURL: tmp)
        let runtime = DirectProviderRuntime(
            credentialStore: creds,
            modelRegistry: registry,
            sessionStore: store
        )
        let ids = runtime.registeredProviderIds
        #expect(ids.contains("openai"))
        #expect(ids.contains("anthropic"))
        #expect(ids.contains("deepseek"))
        #expect(ids.contains("xai"))
        #expect(ids.contains("relay"))
    }
}

// MARK: - ModelRegistry Tests

@Suite("ModelRegistry")
struct ModelRegistryTests {

    @Test("has bundled default models")
    func hasDefaults() {
        let registry = ModelRegistry()
        let allModels = registry.allModels()
        #expect(allModels.count > 10)
    }

    @Test("default model is deepseek-v4-flash")
    func defaultModel() {
        let registry = ModelRegistry()
        #expect(registry.defaultModelId == "deepseek-v4-flash")
        #expect(registry.defaultProviderId == "deepseek")
        #expect(registry.defaultModel != nil)
        #expect(registry.defaultModel?.name == "DeepSeek V4 Flash")
    }

    @Test("query model by provider and id")
    func queryModel() {
        let registry = ModelRegistry()
        let model = registry.model(provider: "openai", id: "gpt-4.1")
        #expect(model != nil)
        #expect(model?.name == "GPT-4.1")
        #expect(model?.pricing?.inputPerMillion == 2.00)
    }

    @Test("list models for provider")
    func listModels() {
        let registry = ModelRegistry()
        let openaiModels = registry.models(for: "openai")
        #expect(openaiModels.count >= 5)
        #expect(openaiModels.allSatisfy { $0.provider == "openai" })
    }

    @Test("list providers")
    func listProviders() {
        let registry = ModelRegistry()
        let providers = registry.providers()
        #expect(providers.contains("openai"))
        #expect(providers.contains("anthropic"))
        #expect(providers.contains("deepseek"))
    }

    @Test("register custom model")
    func registerCustom() {
        let registry = ModelRegistry()
        let custom = ModelInfo(id: "my-model", name: "My Model", provider: "custom")
        registry.register(custom)
        let retrieved = registry.model(provider: "custom", id: "my-model")
        #expect(retrieved?.name == "My Model")
    }

    @Test("estimate cost uses registry pricing")
    func estimateCost() {
        let registry = ModelRegistry()
        // gpt-4.1: $2/M input, $8/M output
        let cost = registry.estimateCost(provider: "openai", modelId: "gpt-4.1", promptTokens: 1000, completionTokens: 500)
        // (1000 * 2 + 500 * 8) / 1_000_000 = (2000 + 4000) / 1_000_000 = 0.006
        #expect(abs(cost - 0.006) < 0.0001)
    }

    @Test("anthropic models support reasoning")
    func anthropicReasoning() {
        let registry = ModelRegistry()
        let sonnet = registry.model(provider: "anthropic", id: "claude-sonnet-4-20250514")
        #expect(sonnet?.supportsReasoning == true)
    }
}

// MARK: - SessionStore Tests

@Suite("SessionStore")
struct SessionStoreTests {

    func makeTempStore() -> SessionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreTests-\(UUID().uuidString)")
        return SessionStore(storageURL: dir)
    }

    @Test("create and load session")
    func createAndLoad() throws {
        let store = makeTempStore()
        try store.createSession(name: "test", model: "gpt-4.1")

        let data = try store.loadSession(name: "test")
        #expect(data.metadata.name == "test")
        #expect(data.metadata.model == "gpt-4.1")
        #expect(data.messages.isEmpty)
        #expect(data.summary == nil)
    }

    @Test("append and load messages")
    func appendMessages() throws {
        let store = makeTempStore()
        try store.createSession(name: "chat1")

        let messages = [
            RuntimeMessage(role: .user, content: "Hello"),
            RuntimeMessage(role: .assistant, content: "Hi there!"),
        ]
        try store.appendMessages(messages, to: "chat1")

        let data = try store.loadSession(name: "chat1")
        #expect(data.messages.count == 2)
        #expect(data.messages[0].role == .user)
        #expect(data.messages[0].content == "Hello")
        #expect(data.messages[1].role == .assistant)
        #expect(data.messages[1].content == "Hi there!")
    }

    @Test("list sessions")
    func listSessions() throws {
        let store = makeTempStore()
        try store.createSession(name: "session-a")
        try store.createSession(name: "session-b")

        let sessions = store.listSessions()
        #expect(sessions.count == 2)
        let names = sessions.map(\.name)
        #expect(names.contains("session-a"))
        #expect(names.contains("session-b"))
    }

    @Test("delete session")
    func deleteSession() throws {
        let store = makeTempStore()
        try store.createSession(name: "to-delete")
        #expect(store.sessionExists(name: "to-delete"))

        try store.deleteSession(name: "to-delete")
        #expect(!store.sessionExists(name: "to-delete"))
    }

    @Test("compact session preserves summary")
    func compactSession() throws {
        let store = makeTempStore()
        try store.createSession(name: "compact-test")

        let oldMessages = (0..<10).map { i in
            RuntimeMessage(role: i % 2 == 0 ? .user : .assistant, content: "Message \(i)")
        }
        try store.appendMessages(oldMessages, to: "compact-test")

        let recentMessages = [
            RuntimeMessage(role: .user, content: "Recent message"),
            RuntimeMessage(role: .assistant, content: "Recent reply"),
        ]
        try store.compactSession(name: "compact-test", summary: "This is a summary", recentMessages: recentMessages)

        let data = try store.loadSession(name: "compact-test")
        #expect(data.summary == "This is a summary")
        #expect(data.messages.count == 2)
        #expect(data.messages[0].content == "Recent message")
    }

    @Test("session not found throws")
    func sessionNotFound() {
        let store = makeTempStore()
        #expect(throws: SessionStoreError.self) {
            _ = try store.loadSession(name: "nonexistent")
        }
    }

    @Test("message with tool calls persists correctly")
    func toolCallPersistence() throws {
        let store = makeTempStore()
        try store.createSession(name: "tools-test")

        let msg = RuntimeMessage(
            role: .assistant,
            content: "I'll run the command.",
            toolCalls: [
                .init(id: "tc_1", name: "run_in_terminal", arguments: "{\"command\":\"ls\"}")
            ]
        )
        let toolResult = RuntimeMessage(
            role: .tool,
            content: "file1.txt\nfile2.txt",
            toolResult: .init(toolCallId: "tc_1", toolName: "run_in_terminal", content: "file1.txt\nfile2.txt")
        )
        try store.appendMessages([msg, toolResult], to: "tools-test")

        let data = try store.loadSession(name: "tools-test")
        #expect(data.messages.count == 2)
        #expect(data.messages[0].toolCalls?.count == 1)
        #expect(data.messages[0].toolCalls?[0].name == "run_in_terminal")
        #expect(data.messages[1].toolResult?.toolCallId == "tc_1")
    }
}

// MARK: - UsageCalculator Tests

@Suite("UsageCalculator")
struct UsageCalculatorTests {

    @Test("record usage and get total")
    func recordAndTotal() {
        let registry = ModelRegistry()
        let calc = UsageCalculator(modelRegistry: registry)

        calc.record(provider: "openai", modelId: "gpt-4.1", promptTokens: 1000, completionTokens: 500)
        calc.record(provider: "openai", modelId: "gpt-4.1", promptTokens: 2000, completionTokens: 1000)

        let total = calc.totalSessionUsage()
        #expect(total.promptTokens == 3000)
        #expect(total.completionTokens == 1500)
        #expect(total.estimatedCost > 0)
    }

    @Test("provider cost takes precedence")
    func providerCostPrecedence() {
        let registry = ModelRegistry()
        let calc = UsageCalculator(modelRegistry: registry)

        let cost = calc.record(provider: "openai", modelId: "gpt-4.1",
                               promptTokens: 1000, completionTokens: 500,
                               providerCost: 0.042)
        #expect(cost == 0.042)
    }

    @Test("reset session clears counters")
    func resetSession() {
        let registry = ModelRegistry()
        let calc = UsageCalculator(modelRegistry: registry)

        calc.record(provider: "openai", modelId: "gpt-4.1", promptTokens: 1000, completionTokens: 500)
        calc.resetSession()

        let total = calc.totalSessionUsage()
        #expect(total.promptTokens == 0)
        #expect(total.estimatedCost == 0)
    }

    @Test("per-model usage breakdown")
    func perModelBreakdown() {
        let registry = ModelRegistry()
        let calc = UsageCalculator(modelRegistry: registry)

        calc.record(provider: "openai", modelId: "gpt-4.1", promptTokens: 1000, completionTokens: 500)
        calc.record(provider: "anthropic", modelId: "claude-sonnet-4-20250514", promptTokens: 2000, completionTokens: 1000)

        let breakdown = calc.usageByModel()
        #expect(breakdown.count == 2)
        #expect(breakdown["openai:gpt-4.1"]?.promptTokens == 1000)
        #expect(breakdown["anthropic:claude-sonnet-4-20250514"]?.promptTokens == 2000)
    }

    @Test("createUsageEvent returns correct event data")
    func createUsageEvent() {
        let registry = ModelRegistry()
        let calc = UsageCalculator(modelRegistry: registry)

        let event = calc.createUsageEvent(provider: "openai", modelId: "gpt-4.1",
                                           promptTokens: 1000, completionTokens: 500)
        #expect(event.model == "gpt-4.1")
        #expect(event.promptTokens == 1000)
        #expect(event.completionTokens == 500)
        #expect(event.cost > 0)
    }
}

// MARK: - ProviderToolDefinition Bridge Tests

@Suite("ProviderToolDefinition")
struct ProviderToolDefinitionTests {

    @Test("convert from ToolDefinition")
    func convertFromToolDefinition() {
        let tool = ToolDefinition(
            name: "test_tool",
            description: "A test tool",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": .object([
                        "type": .string("string"),
                        "description": .string("The input")
                    ])
                ])
            ])
        ) { _ in "result" }

        let providerTool = ProviderToolDefinition(from: tool)
        #expect(providerTool.name == "test_tool")
        #expect(providerTool.description == "A test tool")
        #expect(!providerTool.parametersSchema.isEmpty)
    }
}

// MARK: - RuntimeSessionConfig Tests

@Suite("RuntimeSessionConfig")
struct RuntimeSessionConfigTests {

    @Test("default reasoning effort is high")
    func defaultReasoningEffort() {
        let config = RuntimeSessionConfig()
        #expect(config.reasoningEffort == "high")
    }

    @Test("default streaming is true")
    func defaultStreaming() {
        let config = RuntimeSessionConfig()
        #expect(config.streaming == true)
    }
}

// MARK: - ModelPricing Tests

@Suite("ModelPricing")
struct ModelPricingTests {

    @Test("cost calculation is correct")
    func costCalculation() {
        let pricing = ModelPricing(inputPerMillion: 3.00, outputPerMillion: 15.00)
        // 1000 input + 500 output
        // (1000 * 3 + 500 * 15) / 1_000_000 = (3000 + 7500) / 1_000_000 = 0.0105
        let cost = pricing.cost(promptTokens: 1000, completionTokens: 500)
        #expect(abs(cost - 0.0105) < 0.0001)
    }

    @Test("zero tokens = zero cost")
    func zeroCost() {
        let pricing = ModelPricing(inputPerMillion: 10.00, outputPerMillion: 30.00)
        let cost = pricing.cost(promptTokens: 0, completionTokens: 0)
        #expect(cost == 0)
    }
}

// MARK: - RuntimeMessage Tests

@Suite("RuntimeMessage")
struct RuntimeMessageTests {

    @Test("message identity")
    func messageId() {
        let msg = RuntimeMessage(role: .user, content: "Hello")
        #expect(!msg.id.isEmpty)
    }

    @Test("message with tool calls")
    func messageWithToolCalls() {
        let msg = RuntimeMessage(
            role: .assistant,
            content: "Running command",
            toolCalls: [
                .init(id: "tc_1", name: "shell", arguments: "{\"cmd\":\"ls\"}"),
                .init(id: "tc_2", name: "read_file", arguments: "{\"path\":\"/tmp/f\"}")
            ]
        )
        #expect(msg.toolCalls?.count == 2)
        #expect(msg.toolCalls?[0].name == "shell")
    }

    @Test("message with tool result")
    func messageWithToolResult() {
        let msg = RuntimeMessage(
            role: .tool,
            content: "output text",
            toolResult: .init(toolCallId: "tc_1", toolName: "shell", content: "output text")
        )
        #expect(msg.toolResult?.toolCallId == "tc_1")
        #expect(msg.toolResult?.isError == false)
    }
}

// MARK: - JSONValue Bridge Tests

@Suite("JSONValue Bridge")
struct JSONValueBridgeTests {

    @Test("toDictionary converts nested structure")
    func toDictionary() {
        let value: JSONValue = .object([
            "name": .string("test"),
            "count": .int(42),
            "nested": .object(["key": .string("value")]),
            "list": .array([.int(1), .int(2)])
        ])
        let dict = value.toDictionary()
        #expect(dict["name"] as? String == "test")
        #expect(dict["count"] as? Int == 42)
        #expect((dict["nested"] as? [String: Any])?["key"] as? String == "value")
        #expect((dict["list"] as? [Any])?.count == 2)
    }

    @Test("from dictionary round-trips")
    func fromDictionary() {
        let dict: [String: Any] = [
            "text": "hello",
            "number": 42,
            "flag": true
        ]
        let value = JSONValue.from(dict)
        #expect(value["text"]?.stringValue == "hello")
        #expect(value["number"]?.intValue == 42)
        #expect(value["flag"]?.boolValue == true)
    }
}

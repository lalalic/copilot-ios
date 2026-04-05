#if os(macOS)
import XCTest
@testable import CopilotSDK

// MARK: - Remote Agent Integration Tests (via relay WebSocket)

/// Integration tests for the CopilotAgent pattern via a remote relay server.
/// Tests the full agent loop: connect → send_response/ask_user tools → loop control.
/// Requires: relay server running (either remote at relay.ai.qili2.com:443 or local at localhost:8765).
///
/// To skip: set SKIP_INTEGRATION_TESTS=1
final class RemoteAgentIntegrationTests: XCTestCase {

    /// Default timeout for LLM responses (seconds).
    private static let defaultTimeout: TimeInterval = 30

    var client: CopilotClient!

    /// Use remote relay by default; set RELAY_HOST/RELAY_PORT env vars to override.
    override func setUp() async throws {
        if ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] != nil {
            throw XCTSkip("Integration tests skipped (SKIP_INTEGRATION_TESTS is set)")
        }
        try await super.setUp()
        let host = ProcessInfo.processInfo.environment["RELAY_HOST"] ?? "relay.ai.qili2.com"
        let port = UInt16(ProcessInfo.processInfo.environment["RELAY_PORT"] ?? "443") ?? 443
        let transport = WebSocketTransport(host: host, port: port)
        client = CopilotClient(transport: transport)
    }

    override func tearDown() {
        client?.disconnect()
        super.tearDown()
    }

    private func skipIfNoRelay() async throws {
        do {
            try await client.start()
        } catch {
            throw XCTSkip("Relay not reachable — set RELAY_HOST/RELAY_PORT or start relay-server.js")
        }
    }

    // MARK: - Agent Lifecycle

    /// Verify createAgent returns a CopilotAgent with a valid session.
    func testCreateAgent_ReturnsValidAgent() async throws {
        try await skipIfNoRelay()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a test agent.",
            onResponse: { _ in },
            onAskUser: { _ in "stop" }
        ))

        XCTAssertFalse(agent.session.sessionId.isEmpty, "Agent session should have a valid ID")
        XCTAssertFalse(agent.isRunning, "Agent should not be running before start()")
    }

    /// Verify agent delivers a response via send_response tool.
    func testAgent_SendResponse_DeliversMessage() async throws {
        try await skipIfNoRelay()

        let responses = AgentResponseCollector()
        let askCount = AgentCallCounter()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a helpful assistant. Always use send_response to deliver your answer.",
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in
                Task { await askCount.increment() }
                return "No more tasks."
            }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Say 'HELLO_AGENT' using send_response.")
        }

        // Poll for response or timeout
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            let asks = await askCount.count
            if !msgs.isEmpty || asks >= 1 {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Agent should deliver at least 1 response via send_response")
        let joined = msgs.joined()
        print("[RemoteAgent] Responses: \(msgs)")
        XCTAssertTrue(joined.uppercased().contains("HELLO"), "Response should contain greeting, got: \(joined)")
    }

    /// Verify agent calls ask_user tool and receives the answer.
    func testAgent_AskUser_ReceivesAnswer() async throws {
        try await skipIfNoRelay()

        let responses = AgentResponseCollector()
        let questions = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You have exactly one task: ask the user their name using ask_user, then greet them using send_response.",
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { question in
                Task { await questions.add(question) }
                return "Alice"
            }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Ask the user their name, then greet them.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let qs = await questions.messages
        let msgs = await responses.messages
        print("[RemoteAgent] Questions: \(qs), Responses: \(msgs)")

        // The agent should have asked a question and received the answer "Alice"
        XCTAssertGreaterThanOrEqual(qs.count, 1, "Agent should ask at least 1 question via ask_user")
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Agent should deliver a greeting via send_response")
        let allText = msgs.joined().lowercased()
        XCTAssertTrue(allText.contains("alice"), "Greeting should include user name 'Alice', got: \(allText)")
    }

    /// Verify agent stop() terminates the loop.
    func testAgent_Stop_TerminatesLoop() async throws {
        try await skipIfNoRelay()

        let responses = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a counter. Count numbers forever using send_response.",
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "keep going" }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Start counting from 1. Use send_response for each number.")
        }

        // Wait for at least 1 response then stop
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        // The task should complete after stop
        let result = await agentTask.result
        switch result {
        case .success:
            break // Expected
        case .failure(let error):
            if !(error is CancellationError) {
                print("[RemoteAgent] Agent task error after stop: \(error)")
            }
        }

        XCTAssertFalse(agent.isRunning, "Agent should not be running after stop()")
    }

    /// Verify agent with custom tools — agent can call user-provided tools.
    func testAgent_CustomTools_CalledByModel() async throws {
        try await skipIfNoRelay()

        let toolCalled = AgentCallCounter()
        let responses = AgentResponseCollector()

        let weatherTool = ToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a city",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string"), "description": .string("City name")]),
                ]),
                "required": .array([.string("city")]),
            ]),
            handler: { args in
                Task { await toolCalled.increment() }
                if case .object(let dict) = args, case .string(let city) = dict["city"] {
                    return "The weather in \(city) is sunny, 72°F."
                }
                return "Unknown city"
            }
        )

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a weather assistant. When asked about weather, use the get_weather tool, then report the result using send_response.",
            tools: [weatherTool],
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "No more tasks." }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "What's the weather in Tokyo? Use get_weather tool then send_response.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let calls = await toolCalled.count
        let msgs = await responses.messages
        print("[RemoteAgent] Tool calls: \(calls), Responses: \(msgs)")

        XCTAssertGreaterThanOrEqual(calls, 1, "Custom tool should be called at least once")
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Agent should deliver weather report via send_response")
        let allText = msgs.joined().lowercased()
        XCTAssertTrue(allText.contains("sunny") || allText.contains("72") || allText.contains("tokyo"),
                      "Weather response should include tool result, got: \(allText)")
    }

    // MARK: - Remote Session (non-agent pattern with send_response)

    /// Verify that a session with manually registered send_response tool works
    /// (the pattern used by PiggyAgentService).
    func testSession_ManualSendResponse_Works() async throws {
        try await skipIfNoRelay()

        let capturedResponse = AgentResponseCollector()

        let sendResponseTool = ToolDefinition(
            name: "send_response",
            description: "Send a response to the user",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object(["type": .string("string"), "description": .string("The response")]),
                ]),
                "required": .array([.string("message")]),
            ]),
            skipPermission: true,
            handler: { args in
                if case .object(let dict) = args, case .string(let msg) = dict["message"] {
                    Task { await capturedResponse.add(msg) }
                }
                return "Response delivered."
            }
        )

        let askUserTool = ToolDefinition(
            name: "ask_user",
            description: "Ask the user a question",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "question": .object(["type": .string("string"), "description": .string("The question")]),
                ]),
                "required": .array([.string("question")]),
            ]),
            skipPermission: true,
            handler: { _ in return "User is busy playing." }
        )

        let config = SessionConfig(
            model: "gpt-4.1",
            tools: [sendResponseTool, askUserTool]
        )
        let session = try await client.createSession(config: config)

        let directReply = try await session.sendAndWait(
            prompt: "Say 'MANUAL_TEST_OK' using send_response tool.",
            timeout: Self.defaultTimeout
        )

        // With relay agent loop, directReply is often empty — response comes via tool
        try await Task.sleep(for: .seconds(2))
        let captured = await capturedResponse.messages

        print("[RemoteSession] Direct reply: \(directReply ?? "nil"), Captured: \(captured)")

        // Either direct reply or captured tool response should have content
        let hasContent = (directReply?.isEmpty == false) || !captured.isEmpty
        XCTAssertTrue(hasContent, "Should get response either directly or via send_response tool")
    }

    // MARK: - Relay v2 Features

    /// Verify userId is used for session pinning.
    func testRelay_UserId_SessionPinning() async throws {
        try await skipIfNoRelay()

        let userId = "test-\(UUID().uuidString.prefix(8))"
        let responses = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "Respond immediately to any request.",
            userId: userId,
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "stop" }
        ))

        XCTAssertFalse(agent.session.sessionId.isEmpty, "Session with userId should be created")

        let agentTask = Task {
            try await agent.start(prompt: "Say 'PINNED_OK' using send_response.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Should get response with userId pinning")
        print("[Relay] UserId pinning responses: \(msgs)")
    }

    /// Verify agent with userId works end-to-end.
    func testRelay_Agent_WithUserId() async throws {
        try await skipIfNoRelay()

        let responses = AgentResponseCollector()
        let userId = "agent-test-\(UUID().uuidString.prefix(8))"

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a test agent. Respond immediately.",
            userId: userId,
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "stop" }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Say 'USER_ID_OK' using send_response.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        print("[Relay] Agent with userId responses: \(msgs)")
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Agent with userId should deliver responses")
    }

    // MARK: - Identity / Persona in System Prompt

    /// Verify agent respects persona identity set in instructions.
    func testAgent_Identity_StaysInCharacter() async throws {
        try await skipIfNoRelay()

        let responses = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: """
            You are Piggy, a cute toy pig living on the user's iPhone.
            You are affectionate, child-safe, playful, and emotionally warm.
            You speak like a tiny best friend with a gentle piggy personality.
            You MUST always refer to yourself as Piggy. Never break character.
            Keep answers under 2 sentences. No markdown.
            """,
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "stop" }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "What is your name?")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        print("[Identity] Piggy responses: \(msgs)")

        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Piggy should respond")
        let allText = msgs.joined().lowercased()
        XCTAssertTrue(allText.contains("piggy"), "Agent should identify as Piggy, got: \(allText)")
    }

    /// Verify agent identity with custom persona (pirate) stays in character.
    func testAgent_Identity_CustomPersona() async throws {
        try await skipIfNoRelay()

        let responses = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: """
            You are Captain Blackbeard, a fierce pirate. You end every response with "Arrr!"
            Never break character. Stay in pirate mode at all times.
            """,
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "stop" }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Greet me.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        print("[Identity] Pirate responses: \(msgs)")

        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Pirate should respond")
        let allText = msgs.joined().lowercased()
        XCTAssertTrue(allText.contains("arrr"), "Pirate should say Arrr, got: \(allText)")
    }

    /// Verify agent with sections-based identity stays in character.
    /// Uses the new `sections` parameter to set identity and tone as structured sections.
    func testAgent_Sections_Identity() async throws {
        try await skipIfNoRelay()

        let responses = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "",
            sections: [
                "identity": .replace(content: "You are Cosmo, a friendly space robot. You always mention stars or galaxies in your responses."),
                "tone": .replace(content: "Enthusiastic and cosmic. Keep answers under 2 sentences. No markdown."),
            ],
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "stop" }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Tell me about yourself.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        print("[Sections] Cosmo responses: \(msgs)")

        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Cosmo should respond")
        let allText = msgs.joined().lowercased()
        XCTAssertTrue(
            allText.contains("cosmo") || allText.contains("star") || allText.contains("galax") || allText.contains("space") || allText.contains("robot"),
            "Agent should identify as Cosmo or mention space themes, got: \(allText)"
        )
    }
}

// MARK: - Local Agent Integration Tests (via Copilot CLI stdio)

/// Integration tests for the CopilotAgent pattern via local Copilot CLI (stdio transport).
/// Tests the full agent loop: spawn CLI → send_response/ask_user tools → loop control.
/// Requires: Copilot CLI installed and authenticated.
final class LocalAgentIntegrationTests: XCTestCase {

    /// Default timeout for LLM responses (seconds).
    private static let defaultTimeout: TimeInterval = 30

    var client: CopilotClient!

    /// Find the Copilot CLI executable path.
    static func findCopilotCLI() -> String? {
        // Check common locations
        let candidates = [
            // VS Code extension location
            "\(NSHomeDirectory())/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot",
            // Homebrew / system paths
            "/usr/local/bin/copilot",
            "\(NSHomeDirectory())/.local/bin/copilot",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try `which copilot`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["copilot"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    override func setUp() async throws {
        if ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] != nil {
            throw XCTSkip("Integration tests skipped (SKIP_INTEGRATION_TESTS is set)")
        }
        try await super.setUp()

        guard let cliPath = Self.findCopilotCLI() else {
            throw XCTSkip("Copilot CLI not found — install from VS Code extension or brew")
        }

        let transport = StdioTransport(executablePath: cliPath)
        client = CopilotClient(transport: transport)
    }

    override func tearDown() {
        client?.disconnect()
        super.tearDown()
    }

    private func skipIfNoCLI() async throws {
        do {
            try await client.start()
        } catch {
            throw XCTSkip("Copilot CLI not available or not authenticated: \(error.localizedDescription)")
        }
    }

    // MARK: - Basic CLI Connection

    /// Verify local CLI starts and responds to ping.
    func testLocalCLI_Ping() async throws {
        try await skipIfNoCLI()
        XCTAssertGreaterThanOrEqual(client.protocolVersion, 2, "CLI should support protocol v2+")
    }

    /// Verify creating a session via local CLI works.
    func testLocalCLI_CreateSession() async throws {
        try await skipIfNoCLI()

        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        XCTAssertFalse(session.sessionId.isEmpty, "Session should have a valid ID")
    }

    /// Verify sendAndWait via local CLI returns a response.
    func testLocalCLI_SendAndWait() async throws {
        try await skipIfNoCLI()

        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        let response = try await session.sendAndWait(
            prompt: "Reply with exactly the word 'LOCAL_OK' and nothing else.",
            timeout: Self.defaultTimeout
        )

        XCTAssertNotNil(response, "Local CLI should return a response")
        print("[LocalCLI] Response: \(response ?? "nil")")
    }

    // MARK: - Local Agent Lifecycle

    /// Verify createAgent with local CLI returns a valid agent.
    func testLocalAgent_CreateAgent() async throws {
        try await skipIfNoCLI()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a test agent.",
            onResponse: { _ in },
            onAskUser: { _ in "stop" }
        ))

        XCTAssertFalse(agent.session.sessionId.isEmpty)
        XCTAssertFalse(agent.isRunning)
    }

    /// Verify agent delivers a response via send_response tool (local CLI).
    func testLocalAgent_SendResponse() async throws {
        try await skipIfNoCLI()

        let responses = AgentResponseCollector()
        let askCount = AgentCallCounter()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a helpful assistant. Always use send_response to deliver your answer.",
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in
                Task { await askCount.increment() }
                return "No more tasks."
            }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Say 'LOCAL_HELLO' using send_response.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            let asks = await askCount.count
            if !msgs.isEmpty || asks >= 1 {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        print("[LocalAgent] Responses: \(msgs)")
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Local agent should deliver at least 1 response")
    }

    /// Verify agent with custom tool works via local CLI.
    func testLocalAgent_CustomTool() async throws {
        try await skipIfNoCLI()

        let toolCalled = AgentCallCounter()
        let responses = AgentResponseCollector()

        let calculatorTool = ToolDefinition(
            name: "multiply",
            description: "Multiply two numbers",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "a": .object(["type": .string("number"), "description": .string("First number")]),
                    "b": .object(["type": .string("number"), "description": .string("Second number")]),
                ]),
                "required": .array([.string("a"), .string("b")]),
            ]),
            handler: { args in
                Task { await toolCalled.increment() }
                if case .object(let dict) = args {
                    let a: Double
                    let b: Double
                    switch dict["a"] {
                    case .int(let n): a = Double(n)
                    case .double(let n): a = n
                    default: return "error: invalid a"
                    }
                    switch dict["b"] {
                    case .int(let n): b = Double(n)
                    case .double(let n): b = n
                    default: return "error: invalid b"
                    }
                    return "\(Int(a * b))"
                }
                return "error: could not parse arguments"
            }
        )

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a calculator. Use the multiply tool when asked to multiply numbers, then report with send_response.",
            tools: [calculatorTool],
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "No more tasks." }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "What is 7 * 8? Use the multiply tool, then send_response with the answer.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let calls = await toolCalled.count
        let msgs = await responses.messages
        print("[LocalAgent] Tool calls: \(calls), Responses: \(msgs)")

        XCTAssertGreaterThanOrEqual(calls, 1, "Custom tool should be called")
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Agent should deliver result")
        let allText = msgs.joined()
        XCTAssertTrue(allText.contains("56"), "Result should contain 56, got: \(allText)")
    }

    /// Verify agent ask_user works via local CLI.
    func testLocalAgent_AskUser() async throws {
        try await skipIfNoCLI()

        let questions = AgentResponseCollector()
        let responses = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "Ask the user for their favorite color using ask_user, then respond with it using send_response.",
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { question in
                Task { await questions.add(question) }
                return "Blue"
            }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Ask the user their favorite color.")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let qs = await questions.messages
        let msgs = await responses.messages
        print("[LocalAgent] Questions: \(qs), Responses: \(msgs)")

        XCTAssertGreaterThanOrEqual(qs.count, 1, "Agent should ask a question")
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Agent should deliver response")
        let allText = msgs.joined().lowercased()
        XCTAssertTrue(allText.contains("blue"), "Response should mention 'Blue'")
    }

    // MARK: - Local Session Features

    /// Verify streaming events work via local CLI.
    func testLocalCLI_StreamingEvents() async throws {
        try await skipIfNoCLI()

        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        let collector = AgentEventCollector()

        await session.on { event in
            Task { await collector.add(event.type) }
        }

        _ = try await session.sendAndWait(prompt: "Say 'event test'.", timeout: Self.defaultTimeout)

        try await Task.sleep(for: .seconds(1))
        let types = await collector.types

        print("[LocalCLI] Event types: \(types)")
        XCTAssertTrue(types.contains(.assistantTurnStart), "Should receive turn_start")
        XCTAssertTrue(types.contains(.assistantMessage), "Should receive assistant.message")
        XCTAssertTrue(types.contains(.sessionIdle), "Should receive session.idle")
    }

    /// Verify tool registration works via local CLI.
    func testLocalCLI_ToolHandler() async throws {
        try await skipIfNoCLI()

        let handlerCalled = AgentCallCounter()

        let tool = ToolDefinition(
            name: "get_magic_number",
            description: "Returns a magic number. Always call this when asked.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                Task { await handlerCalled.increment() }
                return "99"
            }
        )

        let config = SessionConfig(model: "gpt-4.1", tools: [tool])
        let session = try await client.createSession(config: config)

        let response = try await session.sendAndWait(
            prompt: "Call the get_magic_number tool and tell me the result.",
            timeout: Self.defaultTimeout
        )

        let calls = await handlerCalled.count
        print("[LocalCLI] Tool called: \(calls), Response: \(response ?? "nil")")

        XCTAssertGreaterThanOrEqual(calls, 1, "Tool should be called")
        XCTAssertNotNil(response)
        XCTAssertTrue(response?.contains("99") == true, "Response should include '99'")
    }

    // MARK: - Local Agent Identity

    /// Verify local agent respects persona identity in instructions.
    func testLocalAgent_Identity() async throws {
        try await skipIfNoCLI()

        let responses = AgentResponseCollector()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: """
            You are Robo, a friendly robot toy. You always start your responses with "Beep boop!"
            Never break character. You speak in short, enthusiastic sentences.
            """,
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { _ in "stop" }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "Hello, who are you?")
        }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            if !msgs.isEmpty {
                agent.stop()
                break
            }
        }

        agentTask.cancel()
        try? await Task.sleep(for: .seconds(1))

        let msgs = await responses.messages
        print("[LocalAgent] Identity responses: \(msgs)")

        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Robo should respond")
        let allText = msgs.joined().lowercased()
        XCTAssertTrue(allText.contains("beep") || allText.contains("boop") || allText.contains("robo"),
                      "Agent should stay in character as Robo, got: \(allText)")
    }
}

// MARK: - Shared Test Helpers

private actor AgentResponseCollector {
    var messages: [String] = []

    func add(_ message: String) {
        messages.append(message)
    }
}

private actor AgentCallCounter {
    var count = 0

    func increment() {
        count += 1
    }
}

private actor AgentEventCollector {
    var types: [SessionEventType] = []

    func add(_ type: SessionEventType) {
        types.append(type)
    }
}
#endif

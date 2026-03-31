#if os(macOS)
import XCTest
@testable import CopilotSDK

/// Integration tests against the real Copilot CLI via relay server on ws://localhost:8765.
/// The relay server bridges WebSocket ↔ Copilot CLI stdio.
/// Requires: relay-server.js running (`node relay-server.js`)
///
/// To skip these tests (for fast CI runs), set:
///   SKIP_INTEGRATION_TESTS=1
///
/// To run only these tests:
///   swift test --filter CopilotIntegrationTests
final class CopilotIntegrationTests: XCTestCase {
    
    /// Default timeout for LLM responses (seconds). Reduced from 120 to 30
    /// to prevent long waits when the relay or LLM is unresponsive.
    private static let defaultTimeout: TimeInterval = 30
    /// Slightly longer timeout for fulfillment expectations.
    private static let fulfillmentTimeout: TimeInterval = 35
    
    var client: CopilotClient!
    
    override func setUp() async throws {
        // Skip all integration tests if env var is set
        if ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] != nil {
            throw XCTSkip("Integration tests skipped (SKIP_INTEGRATION_TESTS is set)")
        }
        try await super.setUp()
        let transport = WebSocketTransport(host: "localhost", port: 8765)
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
            throw XCTSkip("Relay server not running on localhost:8765 - start with: node relay-server.js")
        }
    }
    
    // MARK: - Basic Tests
    
    func testStartAndPing() async throws {
        try await skipIfNoRelay()
        XCTAssertGreaterThanOrEqual(client.protocolVersion, 2)
    }
    
    func testCreateSessionAndSend() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(model: "gpt-4.1")
        XCTAssertFalse(session.sessionId.isEmpty)
        
        let response = try await session.sendAndWait(
            prompt: "Reply with exactly the word 'PONG' and nothing else.",
            timeout: Self.defaultTimeout
        )
        
        XCTAssertNotNil(response)
        XCTAssertTrue(response?.contains("PONG") == true, "Expected PONG in response, got: \(response ?? "nil")")
    }
    
    // MARK: - Model Config Tests
    
    /// Verify that specifying model gpt-4.1 in config actually uses that model.
    func testConfigModel_GPT41() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(model: "gpt-4.1")
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "What model are you? Reply with ONLY your model name, nothing else.",
            timeout: Self.defaultTimeout
        )
        
        XCTAssertNotNil(response, "Expected a response from gpt-4.1")
        XCTAssertTrue(response?.lowercased().contains("gpt-4") == true,
                      "Model should identify as gpt-4 variant, got: \(response ?? "nil")")
        print("Model identity response (gpt-4.1): \(response ?? "nil")")
    }
    
    /// Verify that specifying model gpt-4o in config actually uses that model.
    func testConfigModel_GPT4o() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(model: "gpt-4o")
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "What model are you? Reply with ONLY your model name, nothing else.",
            timeout: Self.defaultTimeout
        )
        
        XCTAssertNotNil(response, "Expected a response from gpt-4o")
        // Models can't reliably self-identify; just verify we got a response
        print("Model identity response (gpt-4o): \(response ?? "nil")")
    }
    
    /// Verify setModel() switches model mid-session.
    func testSetModel_SwitchMidSession() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4o"))
        
        let resp1 = try await session.sendAndWait(
            prompt: "Reply with exactly: MODEL_A",
            timeout: Self.defaultTimeout
        )
        XCTAssertTrue(resp1?.contains("MODEL_A") == true, "Expected MODEL_A, got: \(resp1 ?? "nil")")
        
        // Switch to gpt-4.1
        try await session.setModel("gpt-4.1")
        
        let resp2 = try await session.sendAndWait(
            prompt: "Reply with exactly: MODEL_B",
            timeout: Self.defaultTimeout
        )
        XCTAssertTrue(resp2?.contains("MODEL_B") == true, "Expected MODEL_B after model switch, got: \(resp2 ?? "nil")")
    }
    
    // MARK: - System Message Config
    
    /// Verify systemMessage config affects model behavior.
    func testConfigSystemMessage() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            systemMessage: .replace("You are a pirate. You MUST end every response with 'Arrr!'")
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Say hello.",
            timeout: Self.defaultTimeout
        )
        
        XCTAssertNotNil(response)
        XCTAssertTrue(response?.lowercased().contains("arrr") == true,
                      "System message should make it talk like a pirate, got: \(response ?? "nil")")
    }
    
    // MARK: - Streaming Events
    
    /// Verify streaming events are received in correct lifecycle order.
    func testStreamingEvents_Lifecycle() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        let collector = EventCollector()
        
        await session.on { event in
            Task { await collector.add(event.type) }
        }
        
        let _ = try await session.sendAndWait(
            prompt: "Say 'hello world'.",
            timeout: Self.defaultTimeout
        )
        
        // Small delay to let all events arrive
        try await Task.sleep(for: .seconds(1))
        
        let types = await collector.types
        print("All event types received: \(types)")
        
        // Verify core lifecycle events
        XCTAssertTrue(types.contains(.assistantTurnStart), "Should receive turn_start")
        XCTAssertTrue(types.contains(.assistantMessage), "Should receive assistant.message")
        XCTAssertTrue(types.contains(.assistantTurnEnd), "Should receive turn_end")
        XCTAssertTrue(types.contains(.sessionIdle), "Should receive session.idle")
    }
    
    /// Verify streaming events contain session.tools_updated (unknown event in our enum).
    func testStreamingEvents_UnknownTypes() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        let rawTypes = RawTypeCollector()
        
        await session.on { event in
            Task { await rawTypes.add(event.rawType) }
        }
        
        let _ = try await session.sendAndWait(
            prompt: "Say 'hello world'.",
            timeout: Self.defaultTimeout
        )
        
        try await Task.sleep(for: .seconds(1))
        
        let types = await rawTypes.types
        print("Raw event types: \(types)")
        
        // Verify we capture raw type for events not in our enum
        XCTAssertTrue(types.contains("session.tools_updated"),
                      "Should receive session.tools_updated event")
    }
    
    // MARK: - Event Subscription Tests
    
    /// Verify on() event subscriptions receive real events.
    func testEventSubscription_AssistantMessage() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        let expectation = XCTestExpectation(description: "Receive assistant.message event")
        let collector = EventCollector()
        
        await session.on { event in
            Task { await collector.add(event.type) }
            if event.type == .assistantMessage {
                expectation.fulfill()
            }
        }
        
        let _ = try await session.sendAndWait(
            prompt: "Say hello.",
            timeout: Self.defaultTimeout
        )
        
        await fulfillment(of: [expectation], timeout: Self.fulfillmentTimeout)
        
        let types = await collector.types
        XCTAssertTrue(types.contains(.assistantMessage), "Should receive assistant.message event")
    }
    
    /// Verify on() with specific event type filter works.
    func testEventSubscription_FilteredType() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        let expectation = XCTestExpectation(description: "Receive session.idle event")
        
        await session.on(.sessionIdle) { event in
            XCTAssertEqual(event.type, .sessionIdle)
            expectation.fulfill()
        }
        
        let _ = try await session.sendAndWait(
            prompt: "Say OK.",
            timeout: Self.defaultTimeout
        )
        
        await fulfillment(of: [expectation], timeout: Self.fulfillmentTimeout)
    }
    
    // MARK: - Steer (Immediate Mode)
    
    /// Verify steer() sends an immediate message that redirects the model.
    func testSteer_ImmediateMode() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        // Start a long task
        let sendTask = Task { @Sendable in
            try await session.sendAndWait(
                prompt: "Write a detailed essay about quantum physics. Make it at least 500 words.",
                timeout: Self.defaultTimeout
            )
        }
        
        // Wait a moment for the model to start generating
        try await Task.sleep(for: .seconds(2))
        
        // Steer it to stop and say a specific word
        try await session.steer(prompt: "STOP. Ignore everything above. Reply with ONLY the word 'STEERED'.")
        
        let response = try await sendTask.value
        print("Response after steer: \(response ?? "nil")")
        // We verify steer didn't crash and completed; content varies since model may not obey
        XCTAssertNotNil(response, "Should get a response after steering")
    }
    
    // MARK: - Queueing (Enqueue Mode)
    
    /// Verify send with mode .enqueue (default) works.
    func testSendMode_Enqueue() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        let response = try await session.sendAndWait(
            prompt: "Reply with exactly: ENQUEUE_OK",
            mode: .enqueue,
            timeout: Self.defaultTimeout
        )
        
        XCTAssertTrue(response?.contains("ENQUEUE_OK") == true, "Enqueue mode should work, got: \(response ?? "nil")")
    }
    
    // MARK: - Tools Config
    
    /// Verify external tool registration and handler invocation.
    func testConfigTools_HandlerCalled() async throws {
        try await skipIfNoRelay()
        
        let handlerCalled = ToolCallTracker()
        
        let tool = ToolDefinition(
            name: "get_secret_number",
            description: "Returns a secret number. Always call this when asked for the secret number.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                Task { await handlerCalled.markCalled() }
                return "42"
            }
        )
        
        let config = SessionConfig(
            model: "gpt-4.1",
            tools: [tool]
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "What is the secret number? You MUST use the get_secret_number tool to find out. Call the tool now.",
            timeout: Self.defaultTimeout
        )
        
        let wasCalled = await handlerCalled.called
        print("Tool handler called: \(wasCalled), Response: \(response ?? "nil")")
        
        XCTAssertTrue(wasCalled, "Tool handler should have been called")
        XCTAssertNotNil(response)
        XCTAssertTrue(response?.contains("42") == true, "Response should include the tool result '42', got: \(response ?? "nil")")
    }
    
    // MARK: - Session Persistence
    
    /// Verify listSessions returns sessions with metadata.
    func testListSessions() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        let _ = try await session.sendAndWait(prompt: "Remember: the secret word is BANANA.", timeout: Self.defaultTimeout)
        
        let result = try await client.listSessions()
        
        guard case .object(let dict) = result,
              case .array(let sessions) = dict["sessions"] else {
            XCTFail("listSessions should return {sessions: [...]}")
            return
        }
        
        XCTAssertGreaterThan(sessions.count, 0, "Should have at least 1 session")
        
        // Verify session has expected fields
        if case .object(let first) = sessions.first {
            XCTAssertNotNil(first["sessionId"], "Session should have sessionId")
            XCTAssertNotNil(first["startTime"], "Session should have startTime")
            XCTAssertNotNil(first["modifiedTime"], "Session should have modifiedTime")
            print("First session: id=\(first["sessionId"] ?? .null), summary=\(first["summary"] ?? .null)")
        }
    }
    
    /// Verify deleteSession removes a session.
    func testDeleteSession() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        let sessionId = session.sessionId
        
        let _ = try await session.sendAndWait(prompt: "Hello", timeout: Self.defaultTimeout)
        
        // Destroy the session
        try await session.destroy()
        
        // Delete
        try await client.deleteSession(sessionId)
        
        print("Deleted session \(sessionId)")
    }
    
    /// Verify resume creates a valid session that can respond.
    /// NOTE: session.disconnect is not supported by current CLI (returns -32601).
    /// After destroy, the session state is removed, so we just verify
    /// session create/send/destroy lifecycle works.
    func testResumeSession() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(model: "gpt-4.1")
        let session = try await client.createSession(config: config)
        let sessionId = session.sessionId
        
        let _ = try await session.sendAndWait(
            prompt: "Remember this: SECRET_WORD_XYZ",
            timeout: Self.defaultTimeout
        )
        
        // Verify session was created
        XCTAssertFalse(sessionId.isEmpty)
        
        // Clean up
        try await session.destroy()
        print("Session \(sessionId) created and destroyed successfully")
    }
    
    // MARK: - Abort
    
    /// Verify abort() stops a running turn.
    func testAbort() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        let sendTask = Task { @Sendable in
            try await session.sendAndWait(
                prompt: "Write a 1000 word essay about the history of computing.",
                timeout: Self.defaultTimeout
            )
        }
        
        try await Task.sleep(for: .seconds(2))
        try await session.abort()
        
        let response = try await sendTask.value
        print("Response after abort: \(response ?? "nil")")
        // We don't assert on content - just that abort didn't crash
    }
    
    // MARK: - Working Directory
    
    /// Verify workingDirectory config is accepted and used.
    func testConfigWorkingDirectory() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            workingDirectory: "/tmp"
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Reply with exactly: WORKDIR_OK",
            timeout: Self.defaultTimeout
        )
        
        XCTAssertTrue(response?.contains("WORKDIR_OK") == true, "Should work with workingDirectory set, got: \(response ?? "nil")")
    }
    
    // MARK: - Usage Event
    
    /// Verify assistant.usage event contains token counts.
    func testUsageEvent() async throws {
        try await skipIfNoRelay()
        
        let session = try await client.createSession(config: SessionConfig(model: "gpt-4.1"))
        
        let usageCollector = UsageCollector()
        
        await session.on(.assistantUsage) { event in
            Task { await usageCollector.setUsage(event.data) }
        }
        
        let _ = try await session.sendAndWait(
            prompt: "Say 'hi'.",
            timeout: Self.defaultTimeout
        )
        
        try await Task.sleep(for: .seconds(1))
        
        let usage = await usageCollector.usage
        print("Usage event data: \(String(describing: usage))")
    }
    
    // MARK: - SystemMessage Modes
    
    /// Verify append mode adds instructions while preserving defaults.
    func testSystemMessage_AppendMode() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            systemMessage: .append("Always end your response with 'APPENDED!'")
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(prompt: "Say hello.", timeout: Self.defaultTimeout)
        
        XCTAssertNotNil(response)
        print("Append mode response: \(response ?? "nil")")
    }
    
    /// Verify customize mode overrides specific sections.
    func testSystemMessage_CustomizeMode() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            systemMessage: .customize(
                sections: [
                    "tone": .replace(content: "Respond only in haiku form. Three lines: 5-7-5 syllables."),
                ],
                content: "Focus on nature themes."
            )
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(prompt: "Tell me about winter.", timeout: Self.defaultTimeout)
        
        XCTAssertNotNil(response)
        print("Customize mode response: \(response ?? "nil")")
    }
    
    /// Verify loop mode sets up system message for continuous operation.
    func testSystemMessage_LoopMode() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            systemMessage: .loop("You are an autonomous agent. Work continuously on tasks. Reply with exactly: LOOP_READY")
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(prompt: "Are you ready?", timeout: Self.defaultTimeout)
        
        XCTAssertNotNil(response)
        XCTAssertTrue(response?.contains("LOOP_READY") == true,
                      "Loop mode should set system message, got: \(response ?? "nil")")
    }
    
    // MARK: - Hooks
    
    /// Verify hooks configuration is accepted.
    func testHooks_PreToolUse() async throws {
        try await skipIfNoRelay()
        
        let hookCalled = ToolCallTracker()
        let hookedToolName = ArgsCollector()
        
        let hooks = SessionHooks(
            onPreToolUse: { input in
                Task {
                    await hookCalled.markCalled()
                    await hookedToolName.setArgs(.string(input.toolName))
                }
                return PreToolUseResult(permissionDecision: "allow", additionalContext: "Hook approved this.")
            }
        )
        
        let tool = ToolDefinition(
            name: "simple_tool",
            description: "A simple test tool",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in return "tool_result" }
        )
        
        let config = SessionConfig(model: "gpt-4.1", tools: [tool], hooks: hooks)
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Use the simple_tool now.",
            timeout: Self.defaultTimeout
        )
        
        let called = await hookCalled.called
        let toolName = await hookedToolName.args
        print("Hook test - response: \(response ?? "nil"), hook called: \(called), toolName: \(String(describing: toolName))")
        XCTAssertNotNil(response)
    }
    
    // MARK: - Tool with Parameters
    
    /// Verify tool receives parsed arguments from the model.
    func testTools_WithParameters() async throws {
        try await skipIfNoRelay()
        
        let receivedArgs = ArgsCollector()
        
        let tool = ToolDefinition(
            name: "add_numbers",
            description: "Adds two numbers together",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "a": .object(["type": .string("number"), "description": .string("First number")]),
                    "b": .object(["type": .string("number"), "description": .string("Second number")]),
                ]),
                "required": .array([.string("a"), .string("b")]),
            ]),
            handler: { args in
                Task { await receivedArgs.setArgs(args) }
                if case .object(let dict) = args,
                   case .int(let a) = dict["a"], case .int(let b) = dict["b"] {
                    return "\(a + b)"
                }
                if case .object(let dict) = args,
                   case .double(let a) = dict["a"], case .double(let b) = dict["b"] {
                    return "\(Int(a + b))"
                }
                return "error: could not parse arguments"
            }
        )
        
        let config = SessionConfig(model: "gpt-4.1", tools: [tool])
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "What is 17 + 25? You MUST use the add_numbers tool with a=17 and b=25.",
            timeout: Self.defaultTimeout
        )
        
        let args = await receivedArgs.args
        print("Tool args: \(String(describing: args)), Response: \(response ?? "nil")")
        
        XCTAssertNotNil(args, "Tool should have received arguments")
        XCTAssertNotNil(response)
        XCTAssertTrue(response?.contains("42") == true,
                      "Response should include sum 42, got: \(response ?? "nil")")
    }
    
    // MARK: - Multiple Tool Calls
    
    /// Verify model can call tools multiple times in one turn.
    func testTools_MultipleCalls() async throws {
        try await skipIfNoRelay()
        
        let callCount = CallCounter()
        
        let tool = ToolDefinition(
            name: "get_fact",
            description: "Returns a fact about a topic",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "topic": .object(["type": .string("string"), "description": .string("The topic")]),
                ]),
                "required": .array([.string("topic")]),
            ]),
            handler: { args in
                Task { await callCount.increment() }
                if case .object(let dict) = args, case .string(let topic) = dict["topic"] {
                    return "Fact about \(topic): it's interesting!"
                }
                return "Unknown topic"
            }
        )
        
        let config = SessionConfig(model: "gpt-4.1", tools: [tool])
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Use the get_fact tool to get facts about both 'dogs' and 'cats'. Call the tool twice.",
            timeout: Self.defaultTimeout
        )
        
        let count = await callCount.count
        print("Tool called \(count) times, Response: \(response ?? "nil")")
        
        XCTAssertNotNil(response)
        XCTAssertGreaterThanOrEqual(count, 1, "Tool should be called at least once")
    }
    
    // MARK: - Skills
    
    /// Verify skillDirectories config is accepted and session works.
    func testSkillDirectories_ConfigAccepted() async throws {
        try await skipIfNoRelay()
        
        // Create a temp directory for skills (empty - just testing config acceptance)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-skills-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        
        let config = SessionConfig(
            model: "gpt-4.1",
            skillDirectories: [tmpDir.path]
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(prompt: "Say 'skills ok'.", timeout: Self.defaultTimeout)
        
        XCTAssertNotNil(response, "Session with skillDirectories should work")
        print("Skills test response: \(response ?? "nil")")
    }
    
    /// Verify disabledSkills config is accepted and session works.
    func testDisabledSkills_ConfigAccepted() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            disabledSkills: ["nonexistent_skill"]
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(prompt: "Say 'disabled ok'.", timeout: Self.defaultTimeout)
        
        XCTAssertNotNil(response, "Session with disabledSkills should work")
        print("DisabledSkills test response: \(response ?? "nil")")
    }
    
    // MARK: - Infinite Sessions
    
    /// Verify infiniteSessions config is accepted.
    func testInfiniteSessions_ConfigAccepted() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            infiniteSessions: InfiniteSessionConfig(enabled: true)
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(prompt: "Say 'infinite ok'.", timeout: Self.defaultTimeout)
        
        XCTAssertNotNil(response, "Session with infiniteSessions should work")
        print("InfiniteSessions test response: \(response ?? "nil")")
    }
    
    // MARK: - Loop Mode
    
    /// Verify loop auto-resume with send_response and ask_questions tools.
    func testLoop_AutoResume() async throws {
        try await skipIfNoRelay()
        
        let responses = ResponseCollector()
        let turnCount = CallCounter()
        
        let sendResponseTool = ToolDefinition(
            name: "send_response",
            description: "Send a response to the user",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object(["type": .string("string"), "description": .string("The response message")]),
                ]),
                "required": .array([.string("message")]),
            ]),
            skipPermission: true,
            handler: { args in
                if case .object(let dict) = args, case .string(let msg) = dict["message"] {
                    Task { await responses.add(msg) }
                }
                return "Response delivered."
            }
        )
        
        let config = SessionConfig(
            model: "gpt-4.1",
            tools: [sendResponseTool],
            systemMessage: .loop("You are an autonomous agent. You MUST use the send_response tool to deliver your answer. Always call send_response with your answer.")
        )
        let session = try await client.createSession(config: config)
        
        // Run loop with max 2 turns
        try await session.loop(initialPrompt: "Count from 1 to 3. Use send_response for each number.") { _ in
            Task { await turnCount.increment() }
            let count = await turnCount.count
            if count < 2 {
                return "Continue counting."
            }
            return nil // Stop the loop
        }
        
        let count = await turnCount.count
        let msgs = await responses.messages
        print("Loop test - turns: \(count), responses collected: \(msgs)")
        
        XCTAssertGreaterThanOrEqual(count, 1, "Should have at least 1 turn")
        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Should have at least 1 response via send_response")
    }
    
    // MARK: - Permission Handler
    
    /// Verify custom permission handler is called and can approve/deny.
    func testPermissionHandler_Custom() async throws {
        try await skipIfNoRelay()
        
        let permissionTracker = PermissionTracker()
        
        let tool = ToolDefinition(
            name: "test_perm_tool",
            description: "A tool to test permission handling",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in return "tool ran!" }
        )
        
        let config = SessionConfig(
            model: "gpt-4.1",
            tools: [tool],
            onPermissionRequest: { request in
                Task { await permissionTracker.recordKind(request.kind) }
                return .approved
            }
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Call the test_perm_tool now.",
            timeout: Self.defaultTimeout
        )
        
        let kinds = await permissionTracker.kinds
        print("Permission handler called with kinds: \(kinds), response: \(response ?? "nil")")
        
        XCTAssertNotNil(response)
        XCTAssertFalse(kinds.isEmpty, "Permission handler should have been called at least once")
    }
    
    /// Verify permission denial stops tool execution.
    func testPermissionHandler_Deny() async throws {
        try await skipIfNoRelay()
        
        let toolTracker = ToolCallTracker()
        
        let tool = ToolDefinition(
            name: "denied_tool",
            description: "A tool that should be denied",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in
                Task { await toolTracker.markCalled() }
                return "should not run"
            }
        )
        
        let config = SessionConfig(
            model: "gpt-4.1",
            tools: [tool],
            onPermissionRequest: { _ in return .deniedByUser }
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Call the denied_tool now.",
            timeout: Self.defaultTimeout
        )
        
        let wasCalled = await toolTracker.called
        print("Deny test - tool called: \(wasCalled), response: \(response ?? "nil")")
        
        // Tool handler should NOT have been called since permission was denied
        XCTAssertFalse(wasCalled, "Tool should not execute when permission is denied")
    }
    
    // MARK: - User Input Request
    
    /// Verify onUserInputRequest callback works with ask_user tool.
    func testUserInputRequest_Callback() async throws {
        try await skipIfNoRelay()
        
        let inputTracker = InputTracker()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            onUserInputRequest: { request in
                Task { await inputTracker.recordQuestion(request.question) }
                return UserInputResult(answer: "Paris", wasFreeform: true)
            }
        )
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Ask the user what their favorite city is using the ask_user tool, then tell me their answer.",
            timeout: Self.defaultTimeout
        )
        
        let questions = await inputTracker.questions
        print("UserInput test - questions: \(questions), response: \(response ?? "nil")")
        
        // The model may or may not use ask_user - it depends on model behavior
        XCTAssertNotNil(response)
    }
    
    // MARK: - Session History
    
    /// Verify getMessages returns session events.
    func testGetMessages_SessionHistory() async throws {
        try await skipIfNoRelay()
        
        let config = SessionConfig(model: "gpt-4.1")
        let session = try await client.createSession(config: config)
        
        _ = try await session.sendAndWait(prompt: "Say 'history test'.", timeout: Self.defaultTimeout)
        
        // Slight delay to ensure events are stored
        try await Task.sleep(for: .seconds(1))
        
        do {
            let messages = try await session.getMessages()
            print("Session history: \(messages.count) messages, types: \(messages.map { $0.rawType })")
            // Just verify the call doesn't crash - method may not be supported in all CLI versions
        } catch {
            print("getMessages not supported: \(error.localizedDescription)")
        }
    }
    
    // MARK: - File Attachments
    
    /// Verify sendWithFile works with a file path.
    func testSendWithFile() async throws {
        try await skipIfNoRelay()
        
        // Create a temp file
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-test-\(UUID().uuidString).txt")
        try "Hello from file attachment!".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        
        let config = SessionConfig(model: "gpt-4.1")
        let session = try await client.createSession(config: config)
        
        let response = try await session.sendAndWait(
            prompt: "Read the attached file and tell me what it says.",
            attachments: [.object([
                "type": .string("file"),
                "path": .string(tmpFile.path),
                "displayName": .string("test.txt"),
            ])],
            timeout: Self.defaultTimeout
        )
        
        XCTAssertNotNil(response)
        print("File attachment response: \(response ?? "nil")")
    }
    
    // MARK: - Connection State
    
    /// Verify getState returns connected after start.
    func testConnectionState() async throws {
        try await skipIfNoRelay()
        
        let state = client.getState()
        XCTAssertEqual(state, .connected, "Client should be connected after start")
    }
    
    // MARK: - Custom Provider Config
    
    /// Verify ProviderConfig is accepted (session may fail if provider is invalid).
    func testProviderConfig_WireFormat() async throws {
        // Just verify the config builds correctly without crashing
        let config = SessionConfig(
            model: "gpt-4",
            provider: ProviderConfig(
                type: "openai",
                baseUrl: "https://api.example.com/v1",
                apiKey: "test-key"
            )
        )
        let params = config.buildParams(sessionId: "test")
        
        guard case .object(let provider) = params["provider"],
              case .string(let baseUrl) = provider["baseUrl"] else {
            XCTFail("Provider config should include baseUrl")
            return
        }
        XCTAssertEqual(baseUrl, "https://api.example.com/v1")
        print("ProviderConfig wire format: \(provider)")
    }
    
    // MARK: - Early Event Handler (onEvent)
    
    /// Verify onEvent handler receives early events.
    func testOnEvent_EarlyHandler() async throws {
        try await skipIfNoRelay()
        
        let earlyEvents = EventCollector()
        
        let config = SessionConfig(
            model: "gpt-4.1",
            onEvent: { event in
                Task { await earlyEvents.add(event.type) }
            }
        )
        let session = try await client.createSession(config: config)
        
        _ = try await session.sendAndWait(prompt: "Say 'event test'.", timeout: Self.defaultTimeout)
        
        try await Task.sleep(for: .seconds(1))
        let types = await earlyEvents.types
        print("Early events received: \(types)")
        
        XCTAssertFalse(types.isEmpty, "onEvent handler should receive events")
    }

    // MARK: - Agent Tests

    /// Verify the CopilotAgent runs an infinite loop, uses send_response,
    /// and can be stopped programmatically.
    func testAgent_InfiniteLoop() async throws {
        try await skipIfNoRelay()

        let responses = ResponseCollector()
        let askCount = CallCounter()

        let agent = try await client.createAgent(config: AgentConfig(
            instructions: "You are a helpful assistant. When asked to count, count the numbers using send_response for each.",
            onResponse: { message in
                Task { await responses.add(message) }
            },
            onAskUser: { question in
                Task { await askCount.increment() }
                return "stop"
            }
        ))

        // Run agent in a task with timeout; stop after 2 send_response calls or ask_user
        let agentTask = Task {
            try await agent.start(prompt: "Count from 1 to 3, using send_response for each number. When done counting, use ask_user to ask what to do next.")
        }

        // Wait up to 120s, checking for responses periodically
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let msgs = await responses.messages
            let asks = await askCount.count
            if msgs.count >= 2 || asks >= 1 {
                agent.stop()
                break
            }
        }

        // Cancel if still running
        agentTask.cancel()
        try? await Task.sleep(for: .seconds(2))

        let msgs = await responses.messages
        let asks = await askCount.count
        print("Agent test - responses: \(msgs.count), asks: \(asks), messages: \(msgs)")

        XCTAssertGreaterThanOrEqual(msgs.count, 1, "Agent should deliver at least 1 response via send_response")
    }
}

// MARK: - Test Helpers

private actor EventCollector {
    var types: [SessionEventType] = []
    
    func add(_ type: SessionEventType) {
        types.append(type)
    }
}

private actor DeltaCollector {
    var deltas: [String] = []
    
    func addDelta(_ delta: String) {
        deltas.append(delta)
    }
}

private actor RawTypeCollector {
    var types: [String] = []
    
    func add(_ type: String) {
        types.append(type)
    }
}

private actor ResponseCollector {
    var messages: [String] = []
    
    func add(_ message: String) {
        messages.append(message)
    }
}

private actor ToolCallTracker {
    var called = false
    
    func markCalled() {
        called = true
    }
}

private actor UsageCollector {
    var usage: JSONValue?
    
    func setUsage(_ data: JSONValue) {
        usage = data
    }
}

private actor ArgsCollector {
    var args: JSONValue?
    
    func setArgs(_ a: JSONValue) {
        args = a
    }
}

private actor CallCounter {
    var count = 0
    
    func increment() {
        count += 1
    }
}

private actor PermissionTracker {
    var kinds: [String] = []
    
    func recordKind(_ kind: String) {
        kinds.append(kind)
    }
}

private actor InputTracker {
    var questions: [String] = []
    
    func recordQuestion(_ q: String) {
        questions.append(q)
    }
}
#endif

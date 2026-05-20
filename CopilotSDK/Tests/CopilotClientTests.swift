import XCTest
@testable import CopilotSDK

// MARK: - Mock Transport (Content-Length framing for official SDK protocol)

final class SDKMockTransport: Transport, @unchecked Sendable {
    private let incomingContinuation: AsyncStream<Data>.Continuation
    let incoming: AsyncStream<Data>
    
    private(set) var sentData: [Data] = []
    private(set) var isConnected = false
    private(set) var isDisconnected = false
    
    init() {
        var cont: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { cont = $0 }
        incomingContinuation = cont
    }
    
    func connect() async throws {
        isConnected = true
    }
    
    func disconnect() {
        isDisconnected = true
        incomingContinuation.finish()
    }
    
    func send(_ data: Data) async throws {
        sentData.append(data)
    }
    
    func receive() -> AsyncStream<Data> {
        incoming
    }
    
    /// Simulate receiving a Content-Length framed message
    func simulateMessage(_ json: String) {
        let body = Data(json.utf8)
        incomingContinuation.yield(JSONRPCFraming.frame(body))
    }
    
    /// Parse the last sent Content-Length framed message
    func lastSentJSON() throws -> [String: Any] {
        guard let last = sentData.last else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No data sent"])
        }
        var buffer = last
        guard let body = JSONRPCFraming.extractMessage(from: &buffer) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract"])
        }
        return try JSONSerialization.jsonObject(with: body) as! [String: Any]
    }
    
    /// Parse a specific sent message by index
    func sentJSON(at index: Int) throws -> [String: Any] {
        var buffer = sentData[index]
        guard let body = JSONRPCFraming.extractMessage(from: &buffer) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract"])
        }
        return try JSONSerialization.jsonObject(with: body) as! [String: Any]
    }
}

// MARK: - CopilotClient Tests (Official SDK Protocol)

final class CopilotClientTests: XCTestCase {
    
    var transport: SDKMockTransport!
    var client: CopilotClient!
    
    override func setUp() {
        super.setUp()
        transport = SDKMockTransport()
        client = CopilotClient(transport: transport)
    }
    
    override func tearDown() {
        client.disconnect()
        super.tearDown()
    }
    
    // MARK: - Ping / Start
    
    func testStartSendsPingAndGetsProtocolVersion() async throws {
        let cl = client!
        let tp = transport!
        
        let task = Task {
            try await cl.start()
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Should have sent a ping request
        XCTAssertEqual(tp.sentData.count, 1)
        let json = try tp.sentJSON(at: 0)
        XCTAssertEqual(json["method"] as? String, "ping")
        
        let params = json["params"] as! [String: Any]
        XCTAssertEqual(params["message"] as? String, "hello")
        
        let sentId = json["id"] as! String
        
        // Respond with ping result including protocol version
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"message":"pong: hello","timestamp":1234567890,"protocolVersion":3}}
        """)
        
        try await task.value
        XCTAssertEqual(cl.protocolVersion, 3)
    }
    
    // MARK: - Session Create
    
    func testCreateSession() async throws {
        let cl = client!
        let tp = transport!
        
        try await startClient(cl, tp)
        
        let sessionTask = Task {
            try await cl.createSession(model: "gpt-4.1")
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let json = try tp.lastSentJSON()
        XCTAssertEqual(json["method"] as? String, "session.create")
        
        let params = json["params"] as! [String: Any]
        XCTAssertEqual(params["model"] as? String, "gpt-4.1")
        XCTAssertNotNil(params["sessionId"])
        XCTAssertEqual(params["requestPermission"] as? Bool, true)
        
        let sentId = json["id"] as! String
        let sessionId = params["sessionId"] as! String
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"sessionId":"\(sessionId)"}}
        """)
        
        let session = try await sessionTask.value
        XCTAssertEqual(session.sessionId, sessionId)
    }
    
    // MARK: - Session Send
    
    func testSessionSend() async throws {
        let cl = client!
        let tp = transport!
        
        try await startClient(cl, tp)
        let session = try await createMockSession(cl, tp, sessionId: "s1")
        
        // Send prompt
        let sendTask = Task {
            try await session.send(prompt: "What is 2+2?")
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let json = try tp.lastSentJSON()
        XCTAssertEqual(json["method"] as? String, "session.send")
        
        let params = json["params"] as! [String: Any]
        XCTAssertEqual(params["sessionId"] as? String, "s1")
        XCTAssertEqual(params["prompt"] as? String, "What is 2+2?")
        
        let sentId = json["id"] as! String
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"messageId":"msg-1"}}
        """)
        
        let result = try await sendTask.value
        if case .object(let dict) = result {
            XCTAssertEqual(dict["messageId"], .string("msg-1"))
        } else {
            XCTFail("Expected object result")
        }
    }
    
    // MARK: - Session Send with Blob Attachment
    
    func testSessionSendWithImage() async throws {
        let cl = client!
        let tp = transport!
        
        try await startClient(cl, tp)
        let session = try await createMockSession(cl, tp, sessionId: "s1")
        
        let sendTask = Task {
            try await session.sendWithImage("base64data", mimeType: "image/jpeg", text: "What color?")
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let json = try tp.lastSentJSON()
        XCTAssertEqual(json["method"] as? String, "session.send")
        
        let params = json["params"] as! [String: Any]
        XCTAssertEqual(params["prompt"] as? String, "What color?")
        let attachments = params["attachments"] as! [[String: Any]]
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0]["type"] as? String, "blob")
        XCTAssertEqual(attachments[0]["data"] as? String, "base64data")
        XCTAssertEqual(attachments[0]["mimeType"] as? String, "image/jpeg")
        
        let sentId = json["id"] as! String
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"messageId":"msg-2"}}
        """)
        
        _ = try await sendTask.value
    }
    
    // MARK: - Permission Auto-Approve
    
    func testPermissionAutoApprove() async throws {
        let cl = client!
        let tp = transport!
        
        try await startClient(cl, tp)
        _ = try await createMockSession(cl, tp, sessionId: "s1")
        
        // Simulate CLI sending permission.request
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"perm-1","method":"permission.request","params":{"sessionId":"s1","permissionRequest":{"kind":"shell","command":"ls"}}}
        """)
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Check that we sent an approval response
        let json = try tp.lastSentJSON()
        XCTAssertEqual(json["id"] as? String, "perm-1")
        let result = json["result"] as! [String: Any]
        let inner = result["result"] as! [String: Any]
        XCTAssertEqual(inner["kind"] as? String, "approved")
    }
    
    // MARK: - Helpers
    
    /// Start client (ping + respond)
    private func startClient(_ cl: CopilotClient, _ tp: SDKMockTransport) async throws {
        let task = Task { try await cl.start() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let json = try tp.lastSentJSON()
        let sentId = json["id"] as! String
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"message":"pong","timestamp":123,"protocolVersion":3}}
        """)
        try await task.value
    }
    
    /// Create a mock session
    private func createMockSession(_ cl: CopilotClient, _ tp: SDKMockTransport, sessionId: String) async throws -> CopilotSession {
        let sessionTask = Task { try await cl.createSession(model: "gpt-4.1") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let json = try tp.lastSentJSON()
        let sentId = json["id"] as! String
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"sessionId":"\(sessionId)"}}
        """)
        return try await sessionTask.value
    }
    
    // MARK: - Relay v2 Tests
    
    func testSessionConfigIncludesRelayV2Fields() async throws {
        let config = SessionConfig(
            model: "gpt-4.1",
            snapshot: "base64snapshotdata==",
            appId: "com.example.app",
            userId: "device-abc-123"
        )
        let params = config.buildParams(sessionId: "test-sid")
        XCTAssertEqual(params["userId"], .string("device-abc-123"))
        XCTAssertEqual(params["snapshot"], .string("base64snapshotdata=="))
        XCTAssertEqual(params["appId"], .string("com.example.app"))
        XCTAssertEqual(params["model"], .string("gpt-4.1"))
        XCTAssertEqual(params["sessionId"], .string("test-sid"))
    }
    
    func testSessionConfigOmitsNilRelayV2Fields() async throws {
        let config = SessionConfig(model: "gpt-4.1")
        let params = config.buildParams(sessionId: "test-sid")
        XCTAssertNil(params["snapshot"])
        XCTAssertNil(params["appId"])
        XCTAssertNil(params["userId"])
    }
    
    func testCreateSessionParsesRelayV2ResumedResponse() async throws {
        let cl = client!
        let tp = transport!
        try await startClient(cl, tp)
        
        let config = SessionConfig(model: "gpt-4.1", userId: "user-42")
        let sessionTask = Task { try await cl.createSession(config: config) }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        let json = try tp.lastSentJSON()
        let sentId = json["id"] as! String
        
        // Relay returns resumed session with pending question
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"sessionId":"relay-s1","resumed":true,"pendingQuestion":"What color?","pendingRequestId":"req-99"}}
        """)
        
        let session = try await sessionTask.value
        XCTAssertEqual(session.sessionId, "relay-s1")
        XCTAssertTrue(session.resumed)
        XCTAssertEqual(session.pendingQuestion, "What color?")
        XCTAssertEqual(session.pendingRequestId, "req-99")
        XCTAssertNil(session.snapshotData)
        XCTAssertNil(session.recoveredContext)
    }
    
    func testCreateSessionParsesRelayV2SnapshotResponse() async throws {
        let cl = client!
        let tp = transport!
        try await startClient(cl, tp)
        
        let config = SessionConfig(model: "gpt-4.1", userId: "user-42")
        let sessionTask = Task { try await cl.createSession(config: config) }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        let json = try tp.lastSentJSON()
        let sentId = json["id"] as! String
        
        // Relay returns new session with snapshot + recovered context (hold expired)
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"sessionId":"relay-s2","resumed":false,"snapshot":"UEsDBBQ...","snapshotTimestamp":1710000000,"recoveredContext":"User: hello\\nAssistant: hi"}}
        """)
        
        let session = try await sessionTask.value
        XCTAssertEqual(session.sessionId, "relay-s2")
        XCTAssertFalse(session.resumed)
        XCTAssertEqual(session.snapshotData, "UEsDBBQ...")
        XCTAssertEqual(session.snapshotTimestamp, 1710000000)
        XCTAssertEqual(session.recoveredContext, "User: hello\nAssistant: hi")
        XCTAssertNil(session.pendingQuestion)
    }
    
    func testCreateSessionWithPendingQuestionAsObject() async throws {
        let cl = client!
        let tp = transport!
        try await startClient(cl, tp)
        
        let sessionTask = Task { try await cl.createSession(model: "gpt-4.1") }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        let json = try tp.lastSentJSON()
        let sentId = json["id"] as! String
        
        // Relay sends pendingQuestion as object {question: "..."}
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"sessionId":"relay-s3","resumed":true,"pendingQuestion":{"question":"Pick a number"},"pendingRequestId":"req-55"}}
        """)
        
        let session = try await sessionTask.value
        XCTAssertTrue(session.resumed)
        XCTAssertEqual(session.pendingQuestion, "Pick a number")
        XCTAssertEqual(session.pendingRequestId, "req-55")
    }
    
    func testCreateSessionDefaultsToNonResumed() async throws {
        let cl = client!
        let tp = transport!
        try await startClient(cl, tp)
        
        let sessionTask = Task { try await cl.createSession(model: "gpt-4.1") }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        let json = try tp.lastSentJSON()
        let sentId = json["id"] as! String
        
        // Standard response without relay v2 fields
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"sessionId":"normal-s1"}}
        """)
        
        let session = try await sessionTask.value
        XCTAssertEqual(session.sessionId, "normal-s1")
        XCTAssertFalse(session.resumed)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertNil(session.pendingRequestId)
        XCTAssertNil(session.snapshotData)
        XCTAssertNil(session.snapshotTimestamp)
        XCTAssertNil(session.recoveredContext)
    }

    // MARK: - CustomAgentConfig Tests

    func testCustomAgentConfigWireFormatMinimal() {
        let agent = CustomAgentConfig(name: "researcher")
        let wire = agent.wireFormat
        guard case .object(let dict) = wire else { XCTFail("Expected object"); return }
        XCTAssertEqual(dict["name"], .string("researcher"))
        XCTAssertNil(dict["displayName"])
        XCTAssertNil(dict["description"])
        XCTAssertNil(dict["tools"])
        XCTAssertNil(dict["prompt"])
        XCTAssertNil(dict["infer"])
    }

    func testCustomAgentConfigWireFormatFull() {
        let agent = CustomAgentConfig(
            name: "scene-scout",
            displayName: "Scene Scout",
            description: "Analyzes the environment before filming",
            tools: ["observe_camera", "analyze_vision"],
            prompt: "You are a scene scout. Analyze the environment.",
            infer: true
        )
        let wire = agent.wireFormat
        guard case .object(let dict) = wire else { XCTFail("Expected object"); return }
        XCTAssertEqual(dict["name"], .string("scene-scout"))
        XCTAssertEqual(dict["displayName"], .string("Scene Scout"))
        XCTAssertEqual(dict["description"], .string("Analyzes the environment before filming"))
        XCTAssertEqual(dict["tools"], .array([.string("observe_camera"), .string("analyze_vision")]))
        XCTAssertEqual(dict["prompt"], .string("You are a scene scout. Analyze the environment."))
        XCTAssertEqual(dict["infer"], .bool(true))
    }

    func testSessionConfigIncludesCustomAgents() {
        let config = SessionConfig(
            model: "gpt-4.1",
            customAgents: [
                CustomAgentConfig(name: "researcher", description: "Explores code", tools: ["grep", "describe_media"]),
                CustomAgentConfig(name: "editor", description: "Makes changes", tools: ["edit", "bash"]),
            ],
            agent: "researcher"
        )
        let params = config.buildParams(sessionId: "test-sid")

        // customAgents array should be present
        guard case .array(let agents) = params["customAgents"] else {
            XCTFail("Expected customAgents array"); return
        }
        XCTAssertEqual(agents.count, 2)

        // First agent
        guard case .object(let first) = agents[0] else { XCTFail("Expected object"); return }
        XCTAssertEqual(first["name"], .string("researcher"))
        XCTAssertEqual(first["tools"], .array([.string("grep"), .string("describe_media")]))

        // agent pre-selection
        XCTAssertEqual(params["agent"], .string("researcher"))
    }

    func testSessionConfigOmitsNilCustomAgents() {
        let config = SessionConfig(model: "gpt-4.1")
        let params = config.buildParams(sessionId: "test-sid")
        XCTAssertNil(params["customAgents"])
        XCTAssertNil(params["agent"])
    }
}

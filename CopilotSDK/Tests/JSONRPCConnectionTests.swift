import XCTest
@testable import CopilotSDK

// MARK: - Mock Transport

final class MockTransport: Transport, @unchecked Sendable {
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
    
    // Test helper: simulate receiving raw bytes from server
    func simulateReceive(_ data: Data) {
        incomingContinuation.yield(data)
    }
    
    // Test helper: simulate receiving a framed JSON-RPC message
    func simulateMessage(_ json: String) {
        let body = Data(json.utf8)
        simulateReceive(JSONRPCFraming.frame(body))
    }
}

// MARK: - Connection Tests

final class JSONRPCConnectionTests: XCTestCase {
    
    var transport: MockTransport!
    var connection: JSONRPCConnection!
    
    override func setUp() {
        super.setUp()
        transport = MockTransport()
        connection = JSONRPCConnection(transport: transport)
    }
    
    override func tearDown() {
        connection.close()
        super.tearDown()
    }
    
    // MARK: - Connect
    
    func testConnect() async throws {
        try await connection.start()
        XCTAssertTrue(transport.isConnected)
    }
    
    // MARK: - Request / Response
    
    func testSendRequestAndReceiveResponse() async throws {
        let conn = connection!
        let tp = transport!
        try await conn.start()
        
        let responseTask = Task {
            try await conn.send(method: "ping", params: nil)
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertEqual(tp.sentData.count, 1)
        let sentBody = try extractBody(from: tp.sentData[0])
        let sentJSON = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
        let sentId = sentJSON["id"] as! String
        
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","result":{"message":"pong","protocolVersion":3}}
        """)
        
        let result = try await responseTask.value
        if case .object(let dict) = result {
            XCTAssertEqual(dict["message"], .string("pong"))
            XCTAssertEqual(dict["protocolVersion"], .int(3))
        } else {
            XCTFail("Expected object result")
        }
    }
    
    func testSendRequestAndReceiveError() async throws {
        let conn = connection!
        let tp = transport!
        try await conn.start()
        
        let responseTask = Task {
            do {
                _ = try await conn.send(method: "bad.method", params: nil)
                XCTFail("Should have thrown")
            } catch let error as JSONRPCRemoteError {
                XCTAssertEqual(error.code, -32601)
                XCTAssertEqual(error.message, "Method not found")
            }
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let sentBody = try extractBody(from: tp.sentData[0])
        let sentJSON = try JSONSerialization.jsonObject(with: sentBody) as! [String: Any]
        let sentId = sentJSON["id"] as! String
        
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"\(sentId)","error":{"code":-32601,"message":"Method not found"}}
        """)
        
        _ = await responseTask.result
    }
    
    // MARK: - Notifications
    
    func testReceiveNotification() async throws {
        let conn = connection!
        try await conn.start()
        
        let expectation = XCTestExpectation(description: "Received notification")
        
        let task = Task {
            for await notification in conn.notifications {
                XCTAssertEqual(notification.method, "session.event")
                expectation.fulfill()
                break
            }
        }
        
        transport.simulateMessage("""
        {"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"s1","event":{"type":"message"}}}
        """)
        
        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
    }
    
    // MARK: - Inbound Requests (tool.call from CLI)
    
    func testReceiveInboundRequest() async throws {
        let conn = connection!
        let tp = transport!
        try await conn.start()
        
        let expectation = XCTestExpectation(description: "Received inbound request")
        
        let task = Task {
            for await (id, method, _) in conn.inboundRequests {
                XCTAssertEqual(id, .string("tc-1"))
                XCTAssertEqual(method, "tool.call")
                
                try await conn.respond(to: id, result: .object(["textResultForLlm": .string("Done")]))
                expectation.fulfill()
                break
            }
        }
        
        tp.simulateMessage("""
        {"jsonrpc":"2.0","id":"tc-1","method":"tool.call","params":{"toolName":"camera_see"}}
        """)
        
        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
        
        XCTAssertGreaterThanOrEqual(tp.sentData.count, 1)
        let lastSent = try extractBody(from: tp.sentData.last!)
        let json = try JSONSerialization.jsonObject(with: lastSent) as! [String: Any]
        XCTAssertEqual(json["id"] as? String, "tc-1")
        XCTAssertNotNil(json["result"])
    }
    
    // MARK: - Framing
    
    func testSentDataIsFramed() async throws {
        let conn = connection!
        let tp = transport!
        try await conn.start()
        
        let task = Task {
            try await conn.send(method: "ping", params: nil)
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertEqual(tp.sentData.count, 1)
        let raw = tp.sentData[0]
        let rawStr = String(data: raw, encoding: .utf8)!
        XCTAssertTrue(rawStr.hasPrefix("Content-Length:"), "Sent data should be Content-Length framed")
        
        task.cancel()
    }
    
    // MARK: - Close
    
    func testClose() async throws {
        try await connection.start()
        connection.close()
        XCTAssertTrue(transport.isDisconnected)
    }
    
    // MARK: - Helpers
    
    private func extractBody(from framedData: Data) throws -> Data {
        var buffer = framedData
        guard let body = JSONRPCFraming.extractMessage(from: &buffer) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract body from framed data"])
        }
        return body
    }
}

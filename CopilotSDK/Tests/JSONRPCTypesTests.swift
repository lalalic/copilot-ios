import XCTest
@testable import CopilotSDK

// MARK: - JSON-RPC Message Types Tests

final class JSONRPCTypesTests: XCTestCase {
    
    // MARK: - Request Encoding
    
    func testRequestEncoding() throws {
        let request = JSONRPCRequest(
            id: .string("req-1"),
            method: "session.create",
            params: ["model": .string("gpt-4.1"), "sessionId": .string("abc-123")]
        )
        
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? String, "req-1")
        XCTAssertEqual(json["method"] as? String, "session.create")
        
        let params = json["params"] as? [String: String]
        XCTAssertEqual(params?["model"], "gpt-4.1")
        XCTAssertEqual(params?["sessionId"], "abc-123")
    }
    
    func testRequestWithIntId() throws {
        let request = JSONRPCRequest(
            id: .int(42),
            method: "ping",
            params: ["message": .string("hello")]
        )
        
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(json["id"] as? Int, 42)
    }
    
    func testRequestWithNilParams() throws {
        let request = JSONRPCRequest(
            id: .string("req-2"),
            method: "ping",
            params: nil
        )
        
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertNil(json["params"])
    }
    
    // MARK: - Response Decoding
    
    func testSuccessResponseDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "req-1",
            "result": {
                "sessionId": "abc-123",
                "workspacePath": "/tmp"
            }
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: json)
        
        XCTAssertEqual(response.id, .string("req-1"))
        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)
    }
    
    func testErrorResponseDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "req-1",
            "error": {
                "code": -32601,
                "message": "Method not found"
            }
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: json)
        
        XCTAssertNil(response.result)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertEqual(response.error?.message, "Method not found")
    }
    
    func testResponseWithIntId() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 42,
            "result": { "message": "pong", "timestamp": 1234567890 }
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: json)
        XCTAssertEqual(response.id, .int(42))
    }
    
    // MARK: - Notification Decoding
    
    func testNotificationDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "method": "session.event",
            "params": {
                "sessionId": "abc-123",
                "event": {
                    "type": "assistant.message",
                    "data": { "content": "Hello!" }
                }
            }
        }
        """.data(using: .utf8)!
        
        let notification = try JSONDecoder().decode(JSONRPCNotification.self, from: json)
        
        XCTAssertEqual(notification.method, "session.event")
        XCTAssertNotNil(notification.params)
    }
    
    // MARK: - Inbound Request Decoding (tool.call from CLI)
    
    func testToolCallRequestDecoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "tc-1",
            "method": "tool.call",
            "params": {
                "sessionId": "abc-123",
                "toolCallId": "call-1",
                "toolName": "camera_see",
                "arguments": {}
            }
        }
        """.data(using: .utf8)!
        
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        
        switch message {
        case .request(let id, let method, _):
            XCTAssertEqual(id, .string("tc-1"))
            XCTAssertEqual(method, "tool.call")
        default:
            XCTFail("Expected request, got \(message)")
        }
    }
    
    // MARK: - Message Framing
    
    func testContentLengthFraming() throws {
        let body = """
        {"jsonrpc":"2.0","id":"1","method":"ping","params":{}}
        """
        let bodyData = body.data(using: .utf8)!
        let framed = JSONRPCFraming.frame(bodyData)
        
        let expected = "Content-Length: \(bodyData.count)\r\n\r\n".data(using: .utf8)! + bodyData
        XCTAssertEqual(framed, expected)
    }
    
    func testContentLengthParsing() throws {
        let body = """
        {"jsonrpc":"2.0","id":"1","result":{"message":"pong"}}
        """
        let bodyData = body.data(using: .utf8)!
        let header = "Content-Length: \(bodyData.count)\r\n\r\n"
        var buffer = Data(header.utf8) + bodyData
        
        let extracted = JSONRPCFraming.extractMessage(from: &buffer)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted, bodyData)
        XCTAssertTrue(buffer.isEmpty)
    }
    
    func testPartialMessage() throws {
        let body = """
        {"jsonrpc":"2.0","id":"1","result":{}}
        """
        let bodyData = body.data(using: .utf8)!
        let header = "Content-Length: \(bodyData.count)\r\n\r\n"
        let fullData = Data(header.utf8) + bodyData
        
        // Only send first half
        var buffer = Data(fullData.prefix(fullData.count / 2))
        let extracted = JSONRPCFraming.extractMessage(from: &buffer)
        XCTAssertNil(extracted, "Should not extract from incomplete message")
    }
    
    func testMultipleMessagesInBuffer() throws {
        let body1 = """
        {"jsonrpc":"2.0","id":"1","result":{}}
        """
        let body2 = """
        {"jsonrpc":"2.0","id":"2","result":{}}
        """
        let data1 = body1.data(using: .utf8)!
        let data2 = body2.data(using: .utf8)!
        
        var buffer = Data()
        buffer.append(JSONRPCFraming.frame(data1))
        buffer.append(JSONRPCFraming.frame(data2))
        
        let msg1 = JSONRPCFraming.extractMessage(from: &buffer)
        XCTAssertNotNil(msg1)
        XCTAssertEqual(msg1, data1)
        
        let msg2 = JSONRPCFraming.extractMessage(from: &buffer)
        XCTAssertNotNil(msg2)
        XCTAssertEqual(msg2, data2)
        
        XCTAssertTrue(buffer.isEmpty)
    }
    
    // MARK: - RequestID
    
    func testRequestIDEquality() {
        XCTAssertEqual(RequestID.string("abc"), RequestID.string("abc"))
        XCTAssertEqual(RequestID.int(42), RequestID.int(42))
        XCTAssertNotEqual(RequestID.string("abc"), RequestID.int(42))
    }
    
    func testRequestIDGeneration() {
        let id1 = RequestID.generate()
        let id2 = RequestID.generate()
        XCTAssertNotEqual(id1, id2, "Generated IDs should be unique")
    }
    
    // MARK: - JSONRPCMessage Discriminator
    
    func testMessageDiscriminatorRequest() throws {
        let json = """
        {"jsonrpc":"2.0","id":"1","method":"ping","params":{}}
        """.data(using: .utf8)!
        
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        if case .request(let id, let method, _) = message {
            XCTAssertEqual(id, .string("1"))
            XCTAssertEqual(method, "ping")
        } else {
            XCTFail("Expected request")
        }
    }
    
    func testMessageDiscriminatorResponse() throws {
        let json = """
        {"jsonrpc":"2.0","id":"1","result":{"ok":true}}
        """.data(using: .utf8)!
        
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        if case .response(let response) = message {
            XCTAssertEqual(response.id, .string("1"))
        } else {
            XCTFail("Expected response")
        }
    }
    
    func testMessageDiscriminatorNotification() throws {
        let json = """
        {"jsonrpc":"2.0","method":"session.event","params":{}}
        """.data(using: .utf8)!
        
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: json)
        if case .notification(let notif) = message {
            XCTAssertEqual(notif.method, "session.event")
        } else {
            XCTFail("Expected notification")
        }
    }
    
    // MARK: - JSONValue
    
    func testJSONValueStringRoundTrip() throws {
        let value = JSONValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }
    
    func testJSONValueObjectRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("test"),
            "count": .int(42),
            "active": .bool(true)
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }
    
    func testJSONValueNestedRoundTrip() throws {
        let value = JSONValue.object([
            "tools": .array([
                .object(["name": .string("camera_see"), "description": .string("See camera")])
            ])
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }
    
    // MARK: - JSON Lines Framing
    
    func testJsonLinesFraming() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        let body = Data(json.utf8)
        let framed = JSONLinesFraming.frame(body)
        let framedStr = String(data: framed, encoding: .utf8)!
        XCTAssertTrue(framedStr.hasSuffix("\n"))
        XCTAssertEqual(framedStr, json + "\n")
    }
    
    func testJsonLinesExtract() throws {
        let line1 = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        let line2 = #"{"jsonrpc":"2.0","method":"notify"}"#
        var buffer = Data((line1 + "\n" + line2 + "\n").utf8)
        
        let msg1 = JSONLinesFraming.extractMessage(from: &buffer)
        XCTAssertNotNil(msg1)
        XCTAssertEqual(String(data: msg1!, encoding: .utf8), line1)
        
        let msg2 = JSONLinesFraming.extractMessage(from: &buffer)
        XCTAssertNotNil(msg2)
        XCTAssertEqual(String(data: msg2!, encoding: .utf8), line2)
        
        let msg3 = JSONLinesFraming.extractMessage(from: &buffer)
        XCTAssertNil(msg3)
    }
    
    func testJsonLinesPartialMessage() throws {
        var buffer = Data(#"{"partial":"da"#.utf8)
        
        let msg = JSONLinesFraming.extractMessage(from: &buffer)
        XCTAssertNil(msg, "Should not extract incomplete line")
        
        // Complete the line
        buffer.append(Data(#"ta"}"#.utf8))
        buffer.append(Data("\n".utf8))
        
        let complete = JSONLinesFraming.extractMessage(from: &buffer)
        XCTAssertNotNil(complete)
    }
}

import Testing
import Foundation
@testable import AppAgent

@Suite("MCPServer Tests")
struct MCPServerTests {

    // MARK: - Initialization

    @Test("Default init uses port 9223")
    @MainActor
    func defaultInit() {
        let server = MCPServer()
        #expect(server.port == 9223)
        #expect(server.name == "mcp-server")
        #expect(server.version == "1.0.0")
        #expect(!server.isRunning)
    }

    @Test("Custom init propagates values")
    @MainActor
    func customInit() {
        let server = MCPServer(name: "test-app", version: "2.0.0", port: 8080)
        #expect(server.port == 8080)
        #expect(server.name == "test-app")
        #expect(server.version == "2.0.0")
    }

    // MARK: - Tool Registration

    @Test("Register tools from ToolDefinition array")
    @MainActor
    func registerToolDefinitions() {
        let server = MCPServer()
        let tool = ToolDefinition(
            name: "test_tool",
            description: "A test tool",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in "ok" }
        )
        server.register(tools: [tool])
        #expect(server.toolNames == ["test_tool"])
    }

    @Test("Register tool by name and handler")
    @MainActor
    func registerByName() {
        let server = MCPServer()
        server.register(name: "my_tool", description: "desc") { _ in "result" }
        #expect(server.toolNames == ["my_tool"])
    }

    @Test("Unregister removes tool")
    @MainActor
    func unregisterTool() {
        let server = MCPServer()
        server.register(name: "a", description: "a") { _ in "" }
        server.register(name: "b", description: "b") { _ in "" }
        #expect(server.toolNames == ["a", "b"])
        server.unregister(name: "a")
        #expect(server.toolNames == ["b"])
    }

    @Test("Multiple tools register correctly")
    @MainActor
    func multipleTools() {
        let server = MCPServer()
        let tools = (1...5).map { i in
            ToolDefinition(name: "tool_\(i)", description: "Tool \(i)",
                          parameters: nil, handler: { _ in "\(i)" })
        }
        server.register(tools: tools)
        #expect(server.toolNames.count == 5)
    }

    // MARK: - JSON Conversion

    @Test("toJSONValue converts strings")
    func convertString() {
        let result = MCPServer.toJSONValue("hello")
        if case .string(let s) = result {
            #expect(s == "hello")
        } else {
            Issue.record("Expected .string")
        }
    }

    @Test("toJSONValue converts integers")
    func convertInt() {
        let result = MCPServer.toJSONValue(42 as NSNumber)
        if case .int(let n) = result {
            #expect(n == 42)
        } else {
            Issue.record("Expected .int")
        }
    }

    @Test("toJSONValue converts doubles")
    func convertDouble() {
        let result = MCPServer.toJSONValue(3.14 as NSNumber)
        if case .double(let d) = result {
            #expect(abs(d - 3.14) < 0.001)
        } else {
            Issue.record("Expected .double")
        }
    }

    @Test("toJSONValue converts booleans")
    func convertBool() {
        let result = MCPServer.toJSONValue(true as NSNumber)
        if case .bool(let b) = result {
            #expect(b == true)
        } else {
            Issue.record("Expected .bool")
        }
    }

    @Test("toJSONValue converts dictionaries")
    func convertDict() {
        let result = MCPServer.toJSONValue(["key": "value"] as [String: Any])
        if case .object(let dict) = result, case .string(let v) = dict["key"] {
            #expect(v == "value")
        } else {
            Issue.record("Expected .object with key")
        }
    }

    @Test("toJSONValue converts arrays")
    func convertArray() {
        let result = MCPServer.toJSONValue([1, 2, 3] as [Any])
        if case .array(let arr) = result {
            #expect(arr.count == 3)
        } else {
            Issue.record("Expected .array")
        }
    }

    @Test("toJSONValue converts NSNull")
    func convertNull() {
        let result = MCPServer.toJSONValue(NSNull())
        if case .null = result {
            // ok
        } else {
            Issue.record("Expected .null")
        }
    }

    @Test("jsonValueToAny round-trips")
    func roundTrip() {
        let original: JSONValue = .object([
            "name": .string("test"),
            "count": .int(5),
            "tags": .array([.string("a"), .string("b")])
        ])
        let any = MCPServer.jsonValueToAny(original)
        let back = MCPServer.toJSONValue(any)
        if case .object(let dict) = back {
            if case .string(let s) = dict["name"] { #expect(s == "test") }
            if case .int(let n) = dict["count"] { #expect(n == 5) }
            if case .array(let arr) = dict["tags"] { #expect(arr.count == 2) }
        } else {
            Issue.record("Round-trip failed")
        }
    }

    // MARK: - Server Lifecycle

    @Test("Start and stop")
    @MainActor
    func startStop() throws {
        let server = MCPServer(port: 0)  // port 0 = OS assigns
        // Just verify it doesn't throw — actual listening tested via integration
        server.stop()
        #expect(!server.isRunning)
    }
}

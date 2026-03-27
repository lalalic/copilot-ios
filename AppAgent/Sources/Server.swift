import Foundation
import Network

/// MCP (Model Context Protocol) server using Streamable HTTP transport.
///
/// Runs a lightweight HTTP server via Network.framework that speaks
/// JSON-RPC 2.0 over POST — compatible with VS Code, Claude Desktop,
/// and any MCP client.
///
/// ```swift
/// let server = MCPServer(name: "my-app", port: 9223)
/// server.register(tools: myToolProvider.tools)
/// try server.start()
/// ```
///
/// VS Code `.vscode/mcp.json`:
/// ```json
/// { "servers": { "my-app": { "url": "http://localhost:9223/mcp" } } }
/// ```
@MainActor
public final class MCPServer {

    /// Server identity shown to MCP clients.
    public let name: String

    /// Server version shown to MCP clients.
    public let version: String

    /// TCP port the server listens on.
    public let port: UInt16

    private var listener: NWListener?
    private var toolHandlers: [String: ToolHandler] = [:]
    private var mcpTools: [[String: Any]] = []

    /// Whether the server is currently listening.
    @Published public private(set) var isRunning = false

    /// Log callback for debugging.
    public var onLog: ((String) -> Void)?

    public init(name: String = "mcp-server", version: String = "1.0.0", port: UInt16 = 9223) {
        self.name = name
        self.version = version
        self.port = port
    }

    // MARK: - Tool Registration

    /// Register tools from CopilotSDK `ToolDefinition` array.
    public func register(tools: [ToolDefinition]) {
        for tool in tools {
            toolHandlers[tool.name] = tool.handler
            mcpTools.append(buildMCPSchema(tool))
        }
    }

    /// Register a single tool by name, description, schema, and handler.
    public func register(name: String, description: String,
                         inputSchema: [String: Any] = ["type": "object", "properties": [String: Any]()],
                         handler: @escaping ToolHandler) {
        toolHandlers[name] = handler
        mcpTools.append([
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ])
    }

    /// Unregister a tool by name.
    public func unregister(name: String) {
        toolHandlers.removeValue(forKey: name)
        mcpTools.removeAll { ($0["name"] as? String) == name }
    }

    /// All registered tool names.
    public var toolNames: [String] {
        Array(toolHandlers.keys).sorted()
    }

    // MARK: - Server Lifecycle

    /// Start listening for MCP connections.
    public func start() throws {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.log("MCP Server '\(self.name)' listening on http://0.0.0.0:\(self.port)/mcp")
                case .failed(let error):
                    self.isRunning = false
                    self.log("MCP Server failed: \(error)")
                case .cancelled:
                    self.isRunning = false
                    self.log("MCP Server stopped")
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener.start(queue: .main)
        self.listener = listener
    }

    /// Stop the server.
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - HTTP Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { @MainActor in
                    self?.receiveHTTPRequest(connection: connection)
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receiveHTTPRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] content, _, _, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.log("Receive error: \(error)")
                    connection.cancel()
                    return
                }

                guard let data = content, !data.isEmpty,
                      let raw = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }

                await self.handleHTTPRequest(raw: raw, connection: connection)
            }
        }
    }

    // MARK: - HTTP Request Router

    private func handleHTTPRequest(raw: String, connection: NWConnection) async {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            sendHTTP(connection: connection, status: 400, body: nil)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTP(connection: connection, status: 400, body: nil)
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Extract body
        var body: Data?
        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty {
                body = bodyStr.data(using: .utf8)
            }
        }

        // CORS preflight
        if method == "OPTIONS" {
            sendHTTP(connection: connection, status: 204, body: nil, extraHeaders: [
                "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Session-Id"
            ])
            return
        }

        switch (method, path) {
        case ("POST", "/mcp"):
            await handleMCPPost(body: body, connection: connection)

        case ("GET", "/mcp"):
            // Server-initiated SSE — not needed for basic operation
            sendHTTP(connection: connection, status: 405, body: nil)

        case ("DELETE", "/mcp"):
            // Session termination
            sendHTTP(connection: connection, status: 200, body: nil)

        case ("GET", "/"):
            let info: [String: Any] = [
                "name": name,
                "mcp_endpoint": "/mcp",
                "protocol": "MCP (Streamable HTTP)"
            ]
            sendJSON(connection: connection, status: 200, json: info)

        default:
            sendHTTP(connection: connection, status: 404, body: "Not found".data(using: .utf8))
        }
    }

    // MARK: - MCP JSON-RPC Handler

    private func handleMCPPost(body: Data?, connection: NWConnection) async {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONRPCError(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"]  // Int, String, or nil (notification)
        let method = json["method"] as? String
        let params = json["params"] as? [String: Any] ?? [:]

        // Notifications (no id) — acknowledge with 202
        guard id != nil else {
            sendHTTP(connection: connection, status: 202, body: nil)
            return
        }

        guard let method else {
            sendJSONRPCError(connection: connection, id: id, code: -32600, message: "Missing method")
            return
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-03-26",
                "capabilities": [
                    "tools": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": name,
                    "version": version
                ]
            ]
            sendJSONRPCResult(connection: connection, id: id, result: result)

        case "tools/list":
            sendJSONRPCResult(connection: connection, id: id, result: [
                "tools": mcpTools
            ])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                sendJSONRPCError(connection: connection, id: id, code: -32602, message: "Missing tool name")
                return
            }

            guard let handler = toolHandlers[toolName] else {
                sendJSONRPCError(connection: connection, id: id, code: -32602,
                    message: "Tool '\(toolName)' not found. Available: \(toolNames.joined(separator: ", "))")
                return
            }

            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let jsonArgs = Self.toJSONValue(arguments)

            do {
                let result = try await handler(jsonArgs)

                // Heuristic: long single-line strings are likely base64 images
                let isImage = result.count > 1000 && !result.contains("\n")

                let content: [[String: Any]]
                if isImage {
                    content = [["type": "image", "data": result, "mimeType": "image/jpeg"]]
                } else {
                    content = [["type": "text", "text": result]]
                }

                sendJSONRPCResult(connection: connection, id: id, result: [
                    "content": content,
                    "isError": false
                ])
            } catch {
                sendJSONRPCResult(connection: connection, id: id, result: [
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                    "isError": true
                ])
            }

        case "ping":
            sendJSONRPCResult(connection: connection, id: id, result: [:] as [String: Any])

        default:
            sendJSONRPCError(connection: connection, id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - HTTP Response Helpers

    private func sendJSONRPCResult(connection: NWConnection, id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    private func sendJSONRPCError(connection: NWConnection, id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    private func sendJSON(connection: NWConnection, status: Int, json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            connection.cancel()
            return
        }
        sendHTTP(connection: connection, status: status, body: jsonData, contentType: "application/json")
    }

    private func sendHTTP(connection: NWConnection, status: Int, body: Data?,
                          contentType: String = "application/json",
                          extraHeaders: [String: String] = [:]) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Unknown"
        }

        var headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Access-Control-Allow-Origin: *",
            "Connection: close"
        ]

        if let body, !body.isEmpty {
            headers.append("Content-Type: \(contentType)")
            headers.append("Content-Length: \(body.count)")
        }

        for (key, value) in extraHeaders {
            headers.append("\(key): \(value)")
        }

        headers.append("")
        headers.append("")

        var responseData = Data(headers.joined(separator: "\r\n").utf8)
        if let body { responseData.append(body) }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - MCP Tool Schema Builder

    private func buildMCPSchema(_ tool: ToolDefinition) -> [String: Any] {
        var schema: [String: Any] = ["name": tool.name]
        if let desc = tool.description { schema["description"] = desc }

        if let params = tool.parameters, case .object = params {
            schema["inputSchema"] = jsonValueToAny(params)
        } else {
            schema["inputSchema"] = [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        }

        return schema
    }

    // MARK: - JSON Conversion

    /// Convert Foundation types to `JSONValue`.
    nonisolated public static func toJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let str as String:
            return .string(str)
        case let num as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                return .bool(num.boolValue)
            }
            if num.doubleValue == Double(num.intValue) {
                return .int(num.intValue)
            }
            return .double(num.doubleValue)
        case let dict as [String: Any]:
            return .object(dict.mapValues { toJSONValue($0) })
        case let arr as [Any]:
            return .array(arr.map { toJSONValue($0) })
        case is NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }

    /// Convert `JSONValue` to Foundation types for JSON serialization.
    nonisolated public static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        }
    }

    // Private instance version for internal use
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        Self.jsonValueToAny(value)
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}

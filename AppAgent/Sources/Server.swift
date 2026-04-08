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
    // Dedicated queue for all network I/O — avoids blocking on MainActor
    private let httpQueue = DispatchQueue(label: "mcp-server-http", qos: .userInitiated)
    // Snapshot of state for nonisolated access from httpQueue
    // Written on MainActor during register/start, read on httpQueue — safe by construction
    nonisolated(unsafe) private var _snapshotName: String = ""
    nonisolated(unsafe) private var _snapshotVersion: String = ""
    nonisolated(unsafe) private var _snapshotTools: [[String: Any]] = []
    nonisolated(unsafe) private var _snapshotHandlers: [String: ToolHandler] = [:]
    nonisolated(unsafe) private var _snapshotToolNames: [String] = []

    /// Whether the server is currently listening.
    @Published public private(set) var isRunning = false

    /// Log callback for debugging.
    public var onLog: ((String) -> Void)?

    public init(name: String = "mcp-server", version: String = "1.0.0", port: UInt16 = 9223) {
        self.name = name
        self.version = version
        self.port = port
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Tool Registration

    /// Register tools from CopilotSDK `ToolDefinition` array.
    public func register(tools: [ToolDefinition]) {
        for tool in tools {
            toolHandlers[tool.name] = tool.handler
            mcpTools.append(buildMCPSchema(tool))
        }
        refreshSnapshots()
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
        refreshSnapshots()
    }

    /// Unregister a tool by name.
    public func unregister(name: String) {
        toolHandlers.removeValue(forKey: name)
        mcpTools.removeAll { ($0["name"] as? String) == name }
        refreshSnapshots()
    }

    private func refreshSnapshots() {
        _snapshotName = name
        _snapshotVersion = version
        _snapshotTools = mcpTools
        _snapshotHandlers = toolHandlers
        _snapshotToolNames = toolNames
    }

    /// All registered tool names.
    public var toolNames: [String] {
        Array(toolHandlers.keys).sorted()
    }

    // MARK: - Server Lifecycle

    /// Start listening for MCP connections.
    public func start() throws {
        // Snapshot MainActor-isolated state for use on httpQueue
        _snapshotName = name
        _snapshotVersion = version
        _snapshotTools = mcpTools
        _snapshotHandlers = toolHandlers
        _snapshotToolNames = toolNames

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

        let queue = httpQueue
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.setupConnection(connection, queue: queue)
        }

        listener.start(queue: httpQueue)
        self.listener = listener
    }

    /// Stop the server.
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - HTTP Connection Handling (runs on httpQueue, NOT MainActor)

    /// Set up a new connection — called from httpQueue via newConnectionHandler.
    nonisolated private func setupConnection(_ connection: NWConnection, queue: DispatchQueue) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveHTTPData(connection: connection, accumulated: Data())
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        // Auto-cancel after 180s to prevent CLOSE_WAIT buildup
        // Must be long enough for sub-agent operations (which can take 30-60s)
        queue.asyncAfter(deadline: .now() + 180) { [weak connection] in
            connection?.cancel()
        }
        connection.start(queue: queue)
    }

    /// Accumulate TCP data until full HTTP request is received, then process it.
    nonisolated private func receiveHTTPData(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var data = accumulated
            if let content, !content.isEmpty {
                data.append(content)
            }

            // Check if we have a complete HTTP request
            if let raw = String(data: data, encoding: .utf8),
               let headerEnd = raw.range(of: "\r\n\r\n") {
                let headers = String(raw[raw.startIndex..<headerEnd.lowerBound])
                var expectedContentLength = 0
                for line in headers.split(separator: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let valStr = line.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        expectedContentLength = Int(valStr) ?? 0
                        break
                    }
                }

                let headerEndOffset = raw.distance(from: raw.startIndex, to: headerEnd.upperBound)
                let bodyLength = data.count - headerEndOffset

                if expectedContentLength == 0 || bodyLength >= expectedContentLength {
                    self.processHTTPRequest(raw: String(data: data, encoding: .utf8) ?? raw, connection: connection)
                    return
                }
            }

            if isComplete || (content == nil && accumulated.isEmpty) {
                if data.isEmpty {
                    connection.cancel()
                } else if let raw = String(data: data, encoding: .utf8) {
                    self.processHTTPRequest(raw: raw, connection: connection)
                } else {
                    connection.cancel()
                }
                return
            }

            self.receiveHTTPData(connection: connection, accumulated: data)
        }
    }

    // MARK: - HTTP Request Router (nonisolated — runs on httpQueue)

    nonisolated private func processHTTPRequest(raw: String, connection: NWConnection) {
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
            handleMCPPostNonisolated(body: body, connection: connection)

        case ("GET", "/mcp"):
            sendHTTP(connection: connection, status: 405, body: nil)

        case ("DELETE", "/mcp"):
            sendHTTP(connection: connection, status: 200, body: nil)

        case ("GET", "/"):
            let info: [String: Any] = [
                "name": _snapshotName,
                "mcp_endpoint": "/mcp",
                "protocol": "MCP (Streamable HTTP)"
            ]
            sendJSON(connection: connection, status: 200, json: info)

        default:
            sendHTTP(connection: connection, status: 404, body: "Not found".data(using: .utf8))
        }
    }

    // MARK: - MCP JSON-RPC Handler (nonisolated)

    nonisolated private func handleMCPPostNonisolated(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONRPCError(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"]
        let method = json["method"] as? String
        let params = json["params"] as? [String: Any] ?? [:]

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
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": _snapshotName, "version": _snapshotVersion]
            ]
            sendJSONRPCResult(connection: connection, id: id, result: result)

        case "tools/list":
            sendJSONRPCResult(connection: connection, id: id, result: ["tools": _snapshotTools])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                sendJSONRPCError(connection: connection, id: id, code: -32602, message: "Missing tool name")
                return
            }
            guard let handler = _snapshotHandlers[toolName] else {
                sendJSONRPCError(connection: connection, id: id, code: -32602,
                    message: "Tool '\(toolName)' not found. Available: \(_snapshotToolNames.joined(separator: ", "))")
                return
            }

            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let jsonArgs = Self.toJSONValue(arguments)

            // Tool handlers may need MainActor — run in a detached task
            Task.detached { [weak self] in
                do {
                    let result = try await handler(jsonArgs)
                    let isImage = result.count > 1000 && !result.contains("\n")
                    let content: [[String: Any]] = isImage
                        ? [["type": "image", "data": result, "mimeType": "image/jpeg"]]
                        : [["type": "text", "text": result]]
                    self?.sendJSONRPCResult(connection: connection, id: id, result: [
                        "content": content, "isError": false
                    ])
                } catch {
                    self?.sendJSONRPCResult(connection: connection, id: id, result: [
                        "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                        "isError": true
                    ])
                }
            }

        case "ping":
            sendJSONRPCResult(connection: connection, id: id, result: [:] as [String: Any])

        default:
            sendJSONRPCError(connection: connection, id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - HTTP Response Helpers (nonisolated for httpQueue access)

    nonisolated private func sendJSONRPCResult(connection: NWConnection, id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    nonisolated private func sendJSONRPCError(connection: NWConnection, id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    nonisolated private func sendJSON(connection: NWConnection, status: Int, json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            connection.cancel()
            return
        }
        sendHTTP(connection: connection, status: status, body: jsonData, contentType: "application/json")
    }

    nonisolated private func sendHTTP(connection: NWConnection, status: Int, body: Data?,
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

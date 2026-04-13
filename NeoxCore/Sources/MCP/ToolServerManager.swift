import Foundation
import AppAgent
import CopilotSDK

/// Manages the MCP tool server lifecycle.
/// Apps register their tools; NeoxCore handles HTTP transport via AppAgent.MCPServer.
@MainActor
public final class ToolServerManager: ObservableObject {

    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "toolServerEnabled")
            if isEnabled { tryStart() } else { stop() }
        }
    }

    @Published public var port: Int {
        didSet {
            UserDefaults.standard.set(port, forKey: "toolServerPort")
            if isRunning { restart() }
        }
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    /// The device's WiFi IP address, if available.
    public var localIP: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                       &hostname, socklen_t(hostname.count),
                       nil, 0, NI_NUMERICHOST)
            address = hostname.withUnsafeBufferPointer { buf in
                String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            break
        }
        return address
    }

    /// Full URL for the running server.
    public var serverURL: String {
        let host = localIP ?? "localhost"
        return "http://\(host):\(port)/mcp"
    }

    private var server: MCPServer?
    /// Additional tools registered by the app.
    private var appTools: [(name: String, description: String, schema: [String: Any], handler: @Sendable (AppAgent.JSONValue) async throws -> String)] = []

    public init(enabled: Bool? = nil, port: Int? = nil) {
        self.isEnabled = enabled ?? UserDefaults.standard.bool(forKey: "toolServerEnabled")
        self.port = port ?? {
            let saved = UserDefaults.standard.integer(forKey: "toolServerPort")
            return saved == 0 ? 9223 : saved
        }()
    }

    /// Register a tool to be served over MCP.
    public func register(name: String, description: String, inputSchema: [String: Any], handler: @Sendable @escaping (AppAgent.JSONValue) async throws -> String) {
        appTools.append((name, description, inputSchema, handler))
        // If already running, add to live server
        server?.register(name: name, description: description, inputSchema: inputSchema, handler: handler)
    }

    /// Register AppAgent tools (snapshot, tap, etc.)
    public func registerAppAgent(_ provider: AppAgentToolProvider) {
        server?.register(tools: provider.tools)
    }

    public func tryStart() {
        guard isEnabled, !isRunning else { return }
        lastError = nil

        let srv = MCPServer(name: "neox-core", port: UInt16(port))
        for tool in appTools {
            srv.register(name: tool.name, description: tool.description, inputSchema: tool.schema, handler: tool.handler)
        }
        srv.onLog = { msg in print("[MCPServer] \(msg)") }

        do {
            try srv.start()
            self.server = srv
            isRunning = true
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    public func restart() {
        stop()
        tryStart()
    }
}

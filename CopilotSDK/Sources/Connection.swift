import Foundation
import os

private let sdkLog = Logger(subsystem: "com.copilot.sdk", category: "connection")

// MARK: - Transport Protocol

/// Abstraction over raw byte transport (TCP, pipe, mock).
public protocol Transport: Sendable {
    func connect() async throws
    func disconnect()
    func send(_ data: Data) async throws
    func receive() -> AsyncStream<Data>
}

// MARK: - Framing Mode

/// Determines how JSON-RPC messages are framed on the wire.
enum FramingMode {
    /// Content-Length header framing (LSP-style, for TCP)
    case contentLength
    /// Newline-delimited JSON (ACP-style, for stdio)
    case jsonLines
}

// MARK: - Remote Error

/// Error received from JSON-RPC peer.
struct JSONRPCRemoteError: Error {
    let code: Int
    let message: String
    let data: JSONValue?
}

// MARK: - Pending Request Storage (actor-isolated)

private actor PendingRequests {
    var continuations: [String: CheckedContinuation<JSONValue, Error>] = [:]
    
    func store(_ key: String, _ continuation: CheckedContinuation<JSONValue, Error>) {
        continuations[key] = continuation
    }
    
    func remove(_ key: String) -> CheckedContinuation<JSONValue, Error>? {
        continuations.removeValue(forKey: key)
    }
    
    func removeAll() -> [String: CheckedContinuation<JSONValue, Error>] {
        let all = continuations
        continuations.removeAll()
        return all
    }
}

private actor RequestHandlerRegistry {
    var handlers: [String: RequestHandler] = [:]

    func register(_ method: String, handler: @escaping RequestHandler) {
        handlers[method] = handler
    }

    func handler(for method: String) -> RequestHandler? {
        handlers[method]
    }
}

/// Handler for inbound JSON-RPC requests (e.g., permission.request, tool.call).
public typealias RequestHandler = @Sendable (JSONValue?) async -> JSONValue

// MARK: - JSON-RPC Connection

/// Manages bidirectional JSON-RPC communication over a Transport.
/// Supports Content-Length framing (TCP/LSP) or JSON Lines framing (stdio/ACP).
final class JSONRPCConnection: @unchecked Sendable {
    
    private let transport: Transport
    private let framingMode: FramingMode
    private var receiveTask: Task<Void, Never>?
    private let pending = PendingRequests()
    private let requestHandlers = RequestHandlerRegistry()
    
    // Inbound notifications stream
    private let notificationsContinuation: AsyncStream<JSONRPCNotification>.Continuation
    let notifications: AsyncStream<JSONRPCNotification>
    
    // Inbound requests (e.g. tool.call from CLI)
    private let inboundRequestsContinuation: AsyncStream<(RequestID, String, JSONValue?)>.Continuation
    let inboundRequests: AsyncStream<(RequestID, String, JSONValue?)>
    
    init(transport: Transport, framingMode: FramingMode = .contentLength) {
        self.transport = transport
        self.framingMode = framingMode
        
        var notifCont: AsyncStream<JSONRPCNotification>.Continuation!
        notifications = AsyncStream { notifCont = $0 }
        notificationsContinuation = notifCont
        
        var reqCont: AsyncStream<(RequestID, String, JSONValue?)>.Continuation!
        inboundRequests = AsyncStream { reqCont = $0 }
        inboundRequestsContinuation = reqCont
    }
    
    /// Connect transport and start reading messages.
    func start() async throws {
        try await transport.connect()
        receiveTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Register a handler for inbound RPC requests (e.g., "permission.request").
    /// When the CLI sends a request with this method, the handler is called and
    /// its result is sent back as the response, without going through inboundRequests.
    func registerRequestHandler(_ method: String, handler: @escaping RequestHandler) {
        Task {
            await requestHandlers.register(method, handler: handler)
        }
    }
    
    /// Send a JSON-RPC request and await the response.
    @discardableResult
    func send(method: String, params: [String: JSONValue]?) async throws -> JSONValue {
        let id = RequestID.generate()
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let idKey = keyFor(id)
        
        let data = try JSONEncoder().encode(request)
        let framed = frameData(data)
        
        return try await withCheckedThrowingContinuation { continuation in
            let pending = self.pending
            let transport = self.transport
            Task {
                await pending.store(idKey, continuation)
                do {
                    try await transport.send(framed)
                } catch {
                    if let cont = await pending.remove(idKey) {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    /// Respond to an inbound request (e.g. tool.call result).
    func respond(to id: RequestID, result: JSONValue) async throws {
        struct OutboundResponse: Encodable {
            let jsonrpc = "2.0"
            let id: RequestID
            let result: JSONValue
        }
        
        let resp = OutboundResponse(id: id, result: result)
        let data = try JSONEncoder().encode(resp)
        let framed = frameData(data)
        try await transport.send(framed)
    }

    /// Send a JSON-RPC notification (no id, no response expected).
    func sendNotification(method: String, params: [String: JSONValue]) async throws {
        struct OutboundNotification: Encodable {
            let jsonrpc = "2.0"
            let method: String
            let params: [String: JSONValue]
        }

        let notif = OutboundNotification(method: method, params: params)
        let data = try JSONEncoder().encode(notif)
        let framed = frameData(data)
        try await transport.send(framed)
    }
    
    /// Close the connection.
    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        transport.disconnect()
        notificationsContinuation.finish()
        inboundRequestsContinuation.finish()
        
        Task {
            let allPending = await pending.removeAll()
            for (_, continuation) in allPending {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
    
    // MARK: - Private
    
    private func frameData(_ data: Data) -> Data {
        switch framingMode {
        case .contentLength: return JSONRPCFraming.frame(data)
        case .jsonLines: return JSONLinesFraming.frame(data)
        }
    }
    
    private func readLoop() async {
        var buffer = Data()
        
        for await chunk in transport.receive() {
            buffer.append(chunk)
            
            while let messageData = extractMessage(from: &buffer) {
                await handleMessage(messageData)
            }
        }
        sdkLog.info("🔌 ReadLoop ended — transport stream finished")
    }
    
    private func extractMessage(from buffer: inout Data) -> Data? {
        switch framingMode {
        case .contentLength: return JSONRPCFraming.extractMessage(from: &buffer)
        case .jsonLines: return JSONLinesFraming.extractMessage(from: &buffer)
        }
    }
    
    private func handleMessage(_ data: Data) async {
        do {
            let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)
            
            switch message {
            case .response(let response):
                guard let id = response.id else { return }
                let idKey = keyFor(id)
                
                guard let continuation = await pending.remove(idKey) else { return }
                
                if let error = response.error {
                    continuation.resume(throwing: JSONRPCRemoteError(
                        code: error.code,
                        message: error.message,
                        data: error.data
                    ))
                } else {
                    continuation.resume(returning: response.result ?? .null)
                }
                
            case .notification(let notification):
                NSLog("[Connection] Notification received: method=%@ paramsType=%@", notification.method, notification.params != nil ? "present" : "nil")
                notificationsContinuation.yield(notification)
                
            case .request(let id, let method, let params):
                // Check for registered handler first
                if let handler = await requestHandlers.handler(for: method) {
                    Task {
                        let result = await handler(params)
                        try? await self.respond(to: id, result: result)
                    }
                } else {
                    inboundRequestsContinuation.yield((id, method, params))
                }
            }
        } catch {
            // Malformed message — skip
        }
    }
    
    private func keyFor(_ id: RequestID) -> String {
        switch id {
        case .string(let s): return "s:\(s)"
        case .int(let i): return "i:\(i)"
        }
    }
}

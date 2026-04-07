import Foundation
import os

private let sdkLog = Logger(subsystem: "com.copilot.sdk", category: "websocket")

/// WebSocket transport for CopilotSDK.
/// Connects to a relay server that bridges WebSocket ↔ Copilot CLI stdio.
/// Works on both iOS and macOS.
public final class WebSocketTransport: Transport, @unchecked Sendable {
    
    public let url: URL
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var pingTask: Task<Void, Never>?
    
    public init(url: URL) {
        self.url = url
    }
    
    /// Convenience init for host:port.
    /// Uses wss:// for port 443, ws:// otherwise.
    /// Defaults to production relay at relay.ai.qili2.com:443.
    public convenience init(host: String = "relay.ai.qili2.com", port: UInt16 = 443) {
        let scheme = port == 443 ? "wss" : "ws"
        let urlString = port == 443 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
        guard let url = URL(string: urlString) else {
            // Fallback to localhost if URL is invalid
            self.init(url: URL(string: "ws://localhost:8765")!)
            return
        }
        self.init(url: url)
    }
    
    public func connect() async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 min request timeout
        config.timeoutIntervalForResource = 600 // 10 min resource timeout
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Wait for WebSocket handshake to complete by sending a protocol-level ping
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }

        NSLog("[CopilotSDK] WebSocket connected to %@", url.absoluteString)
        sdkLog.info("🔌 WebSocket connected to \(self.url)")
        
        // Start receive loop
        startReceiving()
        
        // Start keepalive ping every 15s
        startPing()
    }
    
    public func disconnect() {
        // Log stack trace to diagnose premature disconnects
        let stack = Thread.callStackSymbols.prefix(10).joined(separator: "\n")
        NSLog("[CopilotSDK] WebSocket disconnect() called. Stack:\n%@", stack)
        sdkLog.info("🔌 WebSocket disconnect() called")
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        session?.invalidateAndCancel()
        session = nil
    }
    
    public func send(_ data: Data) async throws {
        guard let task = webSocketTask else {
            NSLog("[CopilotSDK] WebSocket send failed: not connected")
            throw WebSocketError.notConnected
        }
        try await task.send(.data(data))
    }
    
    public func receive() -> AsyncStream<Data> {
        AsyncStream { [weak self] continuation in
            self?.streamContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // cleanup handled by disconnect()
            }
        }
    }
    
    // MARK: - Private
    
    private func startReceiving() {
        guard let task = webSocketTask else { return }
        
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self?.streamContinuation?.yield(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self?.streamContinuation?.yield(data)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self?.startReceiving()
                
            case .failure(let error):
                NSLog("[CopilotSDK] WebSocket receive failure: %@", String(describing: error))
                sdkLog.error("🔌 WebSocket receive failure: \(error)")
                self?.pingTask?.cancel()
                self?.pingTask = nil
                self?.streamContinuation?.finish()
            }
        }
    }
    
    /// Periodic ping to keep WebSocket alive
    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let task = self?.webSocketTask else { break }
                task.sendPing { error in
                    if let error {
                        NSLog("[CopilotSDK] WebSocket ping failed: %@", String(describing: error))
                        sdkLog.error("🔌 Ping failed: \(error)")
                    }
                }
            }
        }
    }
    
    enum WebSocketError: Error {
        case notConnected
    }
}

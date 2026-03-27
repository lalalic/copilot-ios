import Foundation

/// WebSocket transport for CopilotSDK.
/// Connects to a relay server that bridges WebSocket ↔ Copilot CLI stdio.
/// Works on both iOS and macOS.
public final class WebSocketTransport: Transport, @unchecked Sendable {
    
    private let url: URL
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    
    public init(url: URL) {
        self.url = url
    }
    
    /// Convenience init for host:port.
    /// Uses wss:// for port 443, ws:// otherwise.
    public convenience init(host: String = "localhost", port: UInt16 = 8765) {
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
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()
        
        // Start receive loop
        startReceiving()
    }
    
    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        session?.invalidateAndCancel()
        session = nil
    }
    
    public func send(_ data: Data) async throws {
        guard let task = webSocketTask else {
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
                
            case .failure:
                self?.streamContinuation?.finish()
            }
        }
    }
    
    enum WebSocketError: Error {
        case notConnected
    }
}

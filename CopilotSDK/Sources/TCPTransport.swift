#if canImport(Network)
import Foundation
import Network

/// TCP transport using Network.framework (NWConnection).
/// Connects to Copilot CLI's JSON-RPC server on localhost.
final class TCPTransport: Transport, @unchecked Sendable {
    
    private let host: String
    private let port: UInt16
    private var nwConnection: NWConnection?
    private var receiveContinuation: AsyncStream<Data>.Continuation?
    private var receiveStream: AsyncStream<Data>?
    
    init(host: String = "localhost", port: UInt16 = 4321) {
        self.host = host
        self.port = port
    }
    
    func connect() async throws {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.nwConnection = connection
        
        var cont: AsyncStream<Data>.Continuation!
        receiveStream = AsyncStream { cont = $0 }
        receiveContinuation = cont
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
        
        // Start reading
        startReceiving()
    }
    
    func disconnect() {
        nwConnection?.cancel()
        nwConnection = nil
        receiveContinuation?.finish()
    }
    
    func send(_ data: Data) async throws {
        guard let connection = nwConnection else {
            throw NSError(domain: "TCPTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    func receive() -> AsyncStream<Data> {
        receiveStream ?? AsyncStream { $0.finish() }
    }
    
    // MARK: - Private
    
    private func startReceiving() {
        guard let connection = nwConnection else { return }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                self?.receiveContinuation?.yield(data)
            }
            if isComplete || error != nil {
                self?.receiveContinuation?.finish()
                return
            }
            // Continue reading
            self?.startReceiving()
        }
    }
}
#endif

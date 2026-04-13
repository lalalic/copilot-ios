import Foundation
import Observation
import CopilotSDK

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

public enum ConnectionError: Error, Equatable {
    case notConfigured
    case connectionFailed(String)
    case timeout
}

@Observable
@MainActor
public final class ConnectionManager {
    public var state: ConnectionState = .disconnected
    public var host: String?
    public var port: UInt16?
    public private(set) var client: CopilotClient?

    public init() {}

    public func configure(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public func configureRelay() {
        configure(host: "relay.ai.qili2.com", port: 443)
    }

    public func connect() async throws {
        guard let host, let port else {
            throw ConnectionError.notConfigured
        }

        state = .connecting

        let transport = WebSocketTransport(host: host, port: port)
        let copilotClient = CopilotClient(transport: transport)

        do {
            try await copilotClient.start()
            self.client = copilotClient
            state = .connected
        } catch {
            state = .disconnected
            throw ConnectionError.connectionFailed(error.localizedDescription)
        }
    }

    public func disconnect() {
        client?.disconnect()
        client = nil
        state = .disconnected
    }
}

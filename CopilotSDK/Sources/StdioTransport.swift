#if os(macOS)
import Foundation

/// Transport that communicates with a subprocess via stdin/stdout pipes.
/// Used to spawn the Copilot CLI in `--headless --stdio` mode.
public final class StdioTransport: Transport, @unchecked Sendable {
    
    private let executablePath: String
    private let arguments: [String]
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    
    public init(executablePath: String, arguments: [String] = ["--headless", "--stdio", "--no-auto-update"]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
    
    public func connect() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        
        try process.run()
    }
    
    public func disconnect() {
        streamContinuation?.finish()
        streamContinuation = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }
    
    public func send(_ data: Data) async throws {
        guard let handle = stdinPipe?.fileHandleForWriting else {
            throw StdioTransportError.notConnected
        }
        handle.write(data)
    }
    
    public func receive() -> AsyncStream<Data> {
        AsyncStream { [weak self] continuation in
            self?.streamContinuation = continuation
            guard let handle = self?.stdoutPipe?.fileHandleForReading else {
                continuation.finish()
                return
            }
            
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                handle.readabilityHandler = nil
            }
        }
    }
    
    enum StdioTransportError: Error {
        case notConnected
    }
}
#endif

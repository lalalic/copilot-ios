import Foundation

// MARK: - SessionStore

/// Local persistence for conversation sessions.
/// Stores sessions as JSONL files with one line per message.
public final class SessionStore: @unchecked Sendable {

    /// Root directory for session storage.
    private let storageURL: URL
    private let lock = NSLock()

    public init(storageURL: URL) {
        self.storageURL = storageURL
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }

    /// Convenience: create a SessionStore in Application Support.
    public convenience init(subdirectory: String = "sessions") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(subdirectory, isDirectory: true)
        self.init(storageURL: dir)
    }

    // MARK: - Session Metadata

    public struct SessionMetadata: Codable, Sendable {
        public var name: String
        public var model: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init(name: String, model: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
            self.name = name
            self.model = model
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    // MARK: - Session Data

    public struct SessionData: Sendable {
        public let metadata: SessionMetadata
        public let messages: [RuntimeMessage]
        public let summary: String?

        public init(metadata: SessionMetadata, messages: [RuntimeMessage], summary: String? = nil) {
            self.metadata = metadata
            self.messages = messages
            self.summary = summary
        }
    }

    // MARK: - Compaction Marker

    private struct CompactionMarker: Codable {
        let type: String  // always "compaction"
        let timestamp: Date
        let originalCount: Int
        let summary: String?
    }

    // MARK: - Persistence

    /// Create a new session file with metadata.
    public func createSession(name: String, model: String? = nil) throws {
        let meta = SessionMetadata(name: name, model: model)
        let fileURL = sessionFileURL(name: name)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metaLine = try encoder.encode(meta)

        var fullData = metaLine
        fullData.append("\n".data(using: .utf8)!)
        try fullData.write(to: fileURL)
    }

    /// Append messages to a session.
    public func appendMessages(_ messages: [RuntimeMessage], to sessionName: String) throws {
        let fileURL = sessionFileURL(name: sessionName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionStoreError.sessionNotFound(sessionName)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var data = Data()
        for message in messages {
            let line = try encoder.encode(PersistentMessage(from: message))
            data.append(line)
            data.append("\n".data(using: .utf8)!)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }

    /// Load a session from disk.
    public func loadSession(name: String) throws -> SessionData {
        let fileURL = sessionFileURL(name: name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionStoreError.sessionNotFound(name)
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw SessionStoreError.corruptedSession(name)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // First line is metadata
        let metaData = Data(lines[0].utf8)
        let metadata = try decoder.decode(SessionMetadata.self, from: metaData)

        var messages: [RuntimeMessage] = []
        var summary: String?

        for i in 1..<lines.count {
            let lineData = Data(lines[i].utf8)

            // Try parsing as compaction marker first
            if let marker = try? decoder.decode(CompactionMarker.self, from: lineData),
               marker.type == "compaction" {
                summary = marker.summary
                continue
            }

            // Try parsing as a message
            if let persistent = try? decoder.decode(PersistentMessage.self, from: lineData) {
                messages.append(persistent.toRuntimeMessage())
            }
        }

        return SessionData(metadata: metadata, messages: messages, summary: summary)
    }

    /// Write a compaction: rewrite the entire session file with metadata + compaction marker + recent messages.
    public func compactSession(name: String, summary: String, recentMessages: [RuntimeMessage]) throws {
        let fileURL = sessionFileURL(name: name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionStoreError.sessionNotFound(name)
        }

        // Load existing metadata
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let firstLine = content.split(separator: "\n", maxSplits: 1).first ?? ""
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(SessionMetadata.self, from: Data(firstLine.utf8))
        metadata.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var data = Data()

        // Metadata line
        let metaLine = try encoder.encode(metadata)
        data.append(metaLine)
        data.append("\n".data(using: .utf8)!)

        // Compaction marker
        let existingData = try loadSession(name: name)
        let marker = CompactionMarker(
            type: "compaction",
            timestamp: Date(),
            originalCount: existingData.messages.count,
            summary: summary
        )
        let markerLine = try encoder.encode(marker)
        data.append(markerLine)
        data.append("\n".data(using: .utf8)!)

        // Recent messages
        for message in recentMessages {
            let line = try encoder.encode(PersistentMessage(from: message))
            data.append(line)
            data.append("\n".data(using: .utf8)!)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    /// List all sessions.
    public func listSessions() -> [SessionMetadata] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { fileURL -> SessionMetadata? in
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                      let firstLine = content.split(separator: "\n", maxSplits: 1).first,
                      let meta = try? decoder.decode(SessionMetadata.self, from: Data(firstLine.utf8)) else {
                    return nil
                }
                return meta
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Delete a session.
    public func deleteSession(name: String) throws {
        let fileURL = sessionFileURL(name: name)
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Check if a session exists.
    public func sessionExists(name: String) -> Bool {
        FileManager.default.fileExists(atPath: sessionFileURL(name: name).path)
    }

    // MARK: - Private

    private func sessionFileURL(name: String) -> URL {
        // Sanitize name for filesystem
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return storageURL.appendingPathComponent("\(safeName).jsonl")
    }
}

// MARK: - Persistent Message Format

/// Internal representation for JSONL serialization.
private struct PersistentMessage: Codable {
    let role: String
    let content: String
    let timestamp: Date
    let model: String?
    let id: String
    let thinking: String?
    let toolCalls: [PersistentToolCall]?
    let toolResult: PersistentToolResult?

    struct PersistentToolCall: Codable {
        let id: String
        let name: String
        let arguments: String
    }

    struct PersistentToolResult: Codable {
        let toolCallId: String
        let toolName: String
        let content: String
        let isError: Bool
    }

    init(from message: RuntimeMessage) {
        self.role = message.role.rawValue
        self.content = message.content
        self.timestamp = message.timestamp
        self.model = message.model
        self.id = message.id
        self.thinking = message.thinking
        self.toolCalls = message.toolCalls?.map {
            PersistentToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
        }
        self.toolResult = message.toolResult.map {
            PersistentToolResult(toolCallId: $0.toolCallId, toolName: $0.toolName,
                                 content: $0.content, isError: $0.isError)
        }
    }

    func toRuntimeMessage() -> RuntimeMessage {
        RuntimeMessage(
            id: id,
            role: RuntimeMessage.Role(rawValue: role) ?? .assistant,
            content: content,
            timestamp: timestamp,
            model: model,
            toolCalls: toolCalls?.map {
                RuntimeMessage.ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments)
            },
            toolResult: toolResult.map {
                RuntimeMessage.ToolResultRecord(toolCallId: $0.toolCallId, toolName: $0.toolName,
                                                content: $0.content, isError: $0.isError)
            },
            thinking: thinking
        )
    }
}

// MARK: - Data append helper

private extension Data {
    mutating func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(self)
        handle.closeFile()
    }
}

// MARK: - Errors

public enum SessionStoreError: Error, LocalizedError {
    case sessionNotFound(String)
    case corruptedSession(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let name):
            return "Session '\(name)' not found"
        case .corruptedSession(let name):
            return "Session '\(name)' is corrupted"
        }
    }
}

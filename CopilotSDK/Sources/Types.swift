import Foundation

// MARK: - Request ID

/// JSON-RPC request identifier — can be string or integer per spec.
public enum RequestID: Codable, Equatable, Hashable {
    case string(String)
    case int(Int)
    
    static func generate() -> RequestID {
        .string(UUID().uuidString)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(
                RequestID.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        }
    }
}

// MARK: - JSON Value (flexible params)

/// A type-erased JSON value for encoding/decoding arbitrary JSON-RPC params.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
    
    // MARK: - Convenience Accessors
    
    /// Extract the string value, or nil if not a string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    
    /// Extract the int value, or nil if not an int.
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
    
    /// Extract a double value. Works for both .double and .int cases.
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    
    /// Extract the bool value, or nil if not a bool.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    
    /// Subscript for object key access.
    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
}

// MARK: - JSON-RPC Request (outbound)

struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: RequestID
    let method: String
    let params: [String: JSONValue]?
}

// MARK: - JSON-RPC Response (inbound)

struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: RequestID?
    let result: JSONValue?
    let error: JSONRPCError?
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
    let data: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case code, message, data
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
    }
}

// MARK: - JSON-RPC Notification (inbound, no id)

public struct JSONRPCNotification: Decodable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?
}

// MARK: - JSON-RPC Message (discriminated union for inbound messages)

enum JSONRPCMessage: Decodable {
    case request(id: RequestID, method: String, params: JSONValue?)
    case response(JSONRPCResponse)
    case notification(JSONRPCNotification)
    
    private enum CodingKeys: String, CodingKey {
        case id, method, result, error, params
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let hasId = container.contains(.id)
        let hasMethod = container.contains(.method)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        
        if hasId && hasMethod {
            // Request (inbound from CLI, e.g. tool.call)
            let id = try container.decode(RequestID.self, forKey: .id)
            let method = try container.decode(String.self, forKey: .method)
            let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
            self = .request(id: id, method: method, params: params)
        } else if hasId && (hasResult || hasError) {
            // Response
            let response = try JSONRPCResponse(from: decoder)
            self = .response(response)
        } else if hasMethod && !hasId {
            // Notification
            let notification = try JSONRPCNotification(from: decoder)
            self = .notification(notification)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Cannot determine JSON-RPC message type")
            )
        }
    }
}

// MARK: - Content-Length Framing (LSP-style)

/// Handles Content-Length header framing used by JSON-RPC over TCP (same as LSP).
enum JSONRPCFraming {
    
    /// Wrap a JSON body with Content-Length header.
    static func frame(_ body: Data) -> Data {
        let header = "Content-Length: \(body.count)\r\n\r\n"
        return Data(header.utf8) + body
    }
    
    /// Try to extract a complete message from the buffer.
    /// Returns the body data if a complete message is available, nil otherwise.
    /// Consumes the extracted bytes from the buffer.
    static func extractMessage(from buffer: inout Data) -> Data? {
        guard let headerEnd = findHeaderEnd(in: buffer) else {
            return nil
        }
        
        let headerData = buffer.prefix(headerEnd)
        guard let headerStr = String(data: headerData, encoding: .utf8),
              let contentLength = parseContentLength(from: headerStr) else {
            return nil
        }
        
        let totalLength = headerEnd + 4 + contentLength // 4 for \r\n\r\n
        guard buffer.count >= totalLength else {
            return nil // Not enough data yet
        }
        
        let bodyStart = buffer.startIndex + headerEnd + 4
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        buffer.removeFirst(totalLength)
        return body
    }
    
    private static func findHeaderEnd(in data: Data) -> Int? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else {
            return nil
        }
        return range.lowerBound - data.startIndex
    }
    
    private static func parseContentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return length
            }
        }
        return nil
    }
}

// MARK: - JSON Lines Framing (ACP-style)

/// Handles newline-delimited JSON framing used by the ACP (Agent Client Protocol).
enum JSONLinesFraming {
    
    /// Wrap a JSON body with a trailing newline.
    static func frame(_ body: Data) -> Data {
        body + Data("\n".utf8)
    }
    
    /// Try to extract a complete JSON line from the buffer.
    /// Returns the body data if a complete line is available, nil otherwise.
    /// Consumes the extracted bytes (including newline) from the buffer.
    static func extractMessage(from buffer: inout Data) -> Data? {
        let newline = UInt8(ascii: "\n")
        guard let newlineIndex = buffer.firstIndex(of: newline) else {
            return nil
        }
        
        let lineData = buffer[buffer.startIndex..<newlineIndex]
        buffer = buffer[(newlineIndex + 1)...]
        
        // Skip empty lines
        let trimmed = lineData.filter { $0 != UInt8(ascii: "\r") }
        if trimmed.isEmpty { return nil }
        
        return Data(trimmed)
    }
}

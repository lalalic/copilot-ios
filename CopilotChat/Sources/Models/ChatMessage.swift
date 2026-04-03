import Foundation

// MARK: - Chat Message

/// A single message in the chat conversation.
public struct ChatMessage: Identifiable, Sendable {
    public let id: UUID
    public let role: Role
    public var content: [ContentBlock]
    public let timestamp: Date
    public var isStreaming: Bool
    public var project: String?

    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
        case system
        case tool
    }

    /// A block of content within a message. Messages can contain multiple blocks
    /// (e.g., text followed by a code block followed by a mermaid diagram).
    public enum ContentBlock: Sendable {
        /// Plain text content.
        case text(String)
        /// Markdown-formatted text (rendered with AttributedString).
        case markdown(String)
        /// Code block with optional language identifier.
        case code(String, language: String?)
        /// Mermaid diagram source code (rendered as inline SVG).
        case mermaid(String)
        /// Inline image data.
        case image(Data, mimeType: String)
        /// File attachment reference.
        case attachment(URL, name: String)
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        content: [ContentBlock],
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        project: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.project = project
    }
}

// MARK: - Tool Call Info

/// Tracks the status of a tool call for UI display.
public struct ToolCallInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public var status: Status
    public var arguments: String?
    public var result: String?

    public enum Status: Sendable, Equatable {
        case running
        case completed
        case failed(String)
    }

    public init(
        id: String,
        name: String,
        status: Status = .running,
        arguments: String? = nil,
        result: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.arguments = arguments
        self.result = result
    }
}

// MARK: - Content Parsing

/// Parse a raw text response into content blocks, detecting code fences and mermaid blocks.
public func parseContentBlocks(_ text: String) -> [ChatMessage.ContentBlock] {
    var blocks: [ChatMessage.ContentBlock] = []
    var current = ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var inCodeBlock = false
    var codeLanguage: String?
    var codeContent = ""

    for line in lines {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        if !inCodeBlock {
            if trimmedLine.hasPrefix("```") {
                // Flush pending markdown
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(.markdown(trimmed))
                }
                current = ""

                // Start code block
                let lang = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
                codeContent = ""
                inCodeBlock = true
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        } else {
            if trimmedLine.hasPrefix("```") {
                // End code block
                inCodeBlock = false
                if codeLanguage?.lowercased() == "mermaid" {
                    blocks.append(.mermaid(codeContent.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    blocks.append(.code(
                        codeContent.trimmingCharacters(in: .whitespacesAndNewlines),
                        language: codeLanguage
                    ))
                }
                codeLanguage = nil
                codeContent = ""
            } else {
                codeContent += (codeContent.isEmpty ? "" : "\n") + line
            }
        }
    }

    // Flush remaining content
    if inCodeBlock {
        // Unclosed code block — treat as code
        blocks.append(.code(codeContent.trimmingCharacters(in: .whitespacesAndNewlines), language: codeLanguage))
    } else {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(.markdown(trimmed))
        }
    }

    return blocks
}

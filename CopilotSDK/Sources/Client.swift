import Foundation
import os

// MARK: - Tool Definition

/// A tool handler receives parsed arguments and returns a result string.
public typealias ToolHandler = @Sendable (JSONValue) async throws -> String

/// Defines a tool that can be called by the Copilot assistant.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String?
    /// JSON Schema for parameters
    public let parameters: JSONValue?
    public let handler: ToolHandler
    /// When true, indicates this tool overrides a built-in tool of the same name
    public let overridesBuiltInTool: Bool
    /// When true, the tool can execute without a permission prompt
    public let skipPermission: Bool

    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue? = nil,
        overridesBuiltInTool: Bool = false,
        skipPermission: Bool = false,
        handler: @escaping ToolHandler
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.overridesBuiltInTool = overridesBuiltInTool
        self.skipPermission = skipPermission
        self.handler = handler
    }

    /// Wire format for provider API tool schemas
    var wireFormat: JSONValue {
        var dict: [String: JSONValue] = ["name": .string(name)]
        if let description { dict["description"] = .string(description) }
        if let parameters { dict["parameters"] = parameters }
        if overridesBuiltInTool { dict["overridesBuiltInTool"] = .bool(true) }
        if skipPermission { dict["skipPermission"] = .bool(true) }
        return .object(dict)
    }
}

// MARK: - System Message Section Action

/// Action for a system message section (used by agent profile parsing).
public enum SystemMessageSectionAction: Sendable {
    case keep
    case remove
    case replace(content: String)
    case prepend(content: String)
    case append(content: String)
}

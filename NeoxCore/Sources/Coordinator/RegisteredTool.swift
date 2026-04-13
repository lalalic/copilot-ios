import Foundation

/// A tool registered with the coordinator, shown in the settings UI.
public struct RegisteredTool: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }

    public static func == (lhs: RegisteredTool, rhs: RegisteredTool) -> Bool {
        lhs.name == rhs.name
    }
}

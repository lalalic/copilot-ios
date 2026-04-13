import Foundation
import CopilotSDK
import CopilotChat

/// Protocol for apps to register custom project type behaviors.
/// Each app implements this to add domain-specific tools and instructions
/// for their project types (e.g., "wechat-assistant", "video-project").
public protocol ProjectTypeHandler: Sendable {
    /// The project type string this handler manages (matches package.json "projectType").
    var projectType: String { get }

    /// Additional tools to register for projects of this type.
    func additionalTools(for projectId: String, workspaceURL: URL) -> [ToolDefinition]

    /// Additional instructions to inject into project session prompts.
    func additionalInstructions(for projectId: String, workspaceURL: URL) -> String

    /// Called after a project session is created, for app-specific wiring.
    func onSessionCreated(projectId: String, session: ChatViewModel)
}

/// Default implementations so handlers only need to override what they use.
public extension ProjectTypeHandler {
    func additionalTools(for projectId: String, workspaceURL: URL) -> [ToolDefinition] { [] }
    func additionalInstructions(for projectId: String, workspaceURL: URL) -> String { "" }
    func onSessionCreated(projectId: String, session: ChatViewModel) {}
}

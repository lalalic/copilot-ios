import Foundation

/// Routes incoming WeChat messages to appropriate handlers/sessions.
///
/// Three-tier routing:
/// 1. Bound contacts → specific session
/// 2. Workspace contacts → auto-create session
/// 3. Unrouted → notification / log
@MainActor
public final class WeChatRouter: ObservableObject {

    /// A binding between a WeChat contact and a session.
    public struct ContactBinding: Codable, Equatable, Sendable {
        public let contactUserName: String
        public let contactName: String
        public let sessionId: String?
        public let workspace: String?

        public init(contactUserName: String, contactName: String,
                    sessionId: String? = nil, workspace: String? = nil) {
            self.contactUserName = contactUserName
            self.contactName = contactName
            self.sessionId = sessionId
            self.workspace = workspace
        }
    }

    /// Route result for a message.
    public enum RouteResult: Sendable {
        case bound(sessionId: String, contactName: String)
        case workspace(workspace: String, contactName: String)
        case unrouted(contactName: String)
    }

    // MARK: - Published State

    @Published public private(set) var bindings: [ContactBinding] = []
    @Published public private(set) var unroutedMessages: [WeChatMessage] = []

    // MARK: - Storage

    private let storageURL: URL

    // MARK: - Init

    public init(storageDirectory: URL? = nil) {
        let dir = storageDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKitAgent", isDirectory: true)
        self.storageURL = dir.appendingPathComponent("wechat-bindings.json")
        loadBindings()
    }

    // MARK: - Routing

    /// Route a message and return the routing decision.
    public func route(_ message: WeChatMessage) -> RouteResult {
        let from = message.fromUserName
        let contactName = message.fromContact?.name ?? from

        // Check bound contacts
        if let binding = bindings.first(where: { $0.contactUserName == from }),
           let sessionId = binding.sessionId {
            return .bound(sessionId: sessionId, contactName: contactName)
        }

        // Check workspace contacts
        if let binding = bindings.first(where: { $0.contactUserName == from }),
           let workspace = binding.workspace {
            return .workspace(workspace: workspace, contactName: contactName)
        }

        // Unrouted
        unroutedMessages.append(message)
        return .unrouted(contactName: contactName)
    }

    // MARK: - Binding Management

    /// Bind a contact to a session.
    public func bind(contactUserName: String, contactName: String, sessionId: String) {
        // Remove existing binding for this contact
        bindings.removeAll { $0.contactUserName == contactUserName }
        let binding = ContactBinding(
            contactUserName: contactUserName,
            contactName: contactName,
            sessionId: sessionId
        )
        bindings.append(binding)
        saveBindings()
    }

    /// Bind a contact to a workspace (auto-create session on first message).
    public func bindToWorkspace(contactUserName: String, contactName: String, workspace: String) {
        bindings.removeAll { $0.contactUserName == contactUserName }
        let binding = ContactBinding(
            contactUserName: contactUserName,
            contactName: contactName,
            workspace: workspace
        )
        bindings.append(binding)
        saveBindings()
    }

    /// Unbind a contact.
    public func unbind(contactUserName: String) {
        bindings.removeAll { $0.contactUserName == contactUserName }
        saveBindings()
    }

    /// Get the binding for a contact.
    public func getBinding(for contactUserName: String) -> ContactBinding? {
        bindings.first { $0.contactUserName == contactUserName }
    }

    // MARK: - Persistence

    private func loadBindings() {
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([ContactBinding].self, from: data) else {
            return
        }
        bindings = loaded
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL)
    }

    /// Clear unrouted messages.
    public func clearUnrouted() {
        unroutedMessages = []
    }
}

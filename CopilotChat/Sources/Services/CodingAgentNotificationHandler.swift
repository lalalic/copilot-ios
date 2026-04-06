import Foundation
import CopilotSDK

// MARK: - Coding Agent Notification Handler
//
// Schema contract between relay MCP tools → APNs → this handler:
//
// All coding agent notifications have:
//   type: "coding_agent"
//   action: "send_response" | "report_progress" | "report_usage"
//   repo: "neos-apps/project-name"
//
// Action-specific fields:
//   send_response: (none — message is in APNs alert body)
//   report_progress: status ("info" | "success" | "warning" | "error")
//   report_usage: model (String), promptTokens (Int), completionTokens (Int), totalTokens (Int)
//
// APNs payload structure:
//   { "aps": { "alert": { "title": "...", "body": "..." } },
//     "type": "coding_agent", "action": "...", "repo": "...", ...action-specific fields }

/// Parsed result from a coding agent notification.
public enum CodingAgentNotification {
    /// A message from the coding agent to display in chat.
    case message(title: String, body: String, repo: String?)
    
    /// A progress milestone (build started, tests passing, etc.)
    case progress(title: String, body: String, repo: String?, status: ProgressStatus)
    
    /// Token usage report for on-device cost tracking.
    case usage(repo: String?, model: String, promptTokens: Int, completionTokens: Int, cost: Double?)
    
    public enum ProgressStatus: String {
        case info, success, warning, error
        
        public var emoji: String {
            switch self {
            case .info: return "ℹ️"
            case .success: return "✅"
            case .warning: return "⚠️"
            case .error: return "❌"
            }
        }
    }
}

/// Handles coding agent notifications from the relay MCP server.
/// Shared across all apps using copilot-ios (Neox, Intento, etc).
public struct CodingAgentNotificationHandler {
    
    /// Parse an APNs notification userInfo into a typed CodingAgentNotification.
    /// Returns nil if the notification is not from a coding agent.
    public static func parse(
        title: String,
        body: String,
        userInfo: [AnyHashable: Any]
    ) -> CodingAgentNotification? {
        let type = userInfo["type"] as? String ?? ""
        guard type == "coding_agent" else { return nil }
        
        let action = userInfo["action"] as? String ?? ""
        let repo = userInfo["repo"] as? String
        
        switch action {
        case "report_usage":
            let model = userInfo["model"] as? String ?? "unknown"
            let promptTokens = (userInfo["promptTokens"] as? Int) ?? 0
            let completionTokens = (userInfo["completionTokens"] as? Int) ?? 0
            let cost = userInfo["cost"] as? Double
            return .usage(repo: repo, model: model, promptTokens: promptTokens, completionTokens: completionTokens, cost: cost)
            
        case "report_progress":
            let statusStr = userInfo["status"] as? String ?? "info"
            let status = CodingAgentNotification.ProgressStatus(rawValue: statusStr) ?? .info
            return .progress(title: title, body: body, repo: repo, status: status)
            
        case "send_response":
            return .message(title: title, body: body, repo: repo)
            
        default:
            // Unknown action — treat as generic message
            return .message(title: title, body: body, repo: repo)
        }
    }
    
    /// Apply a parsed notification: add to chat and/or record usage.
    @MainActor
    public static func apply(
        _ notification: CodingAgentNotification,
        addMessage: (String, String, String?) -> Void,
        usageTracker: UsageTracker?
    ) {
        switch notification {
        case .message(let title, let body, let repo):
            addMessage(title, body, repo)
            
        case .progress(let title, let body, let repo, let status):
            addMessage(title, body, repo)
            
        case .usage(let repo, let model, let promptTokens, let completionTokens, let serverCost):
            // Record usage with server-calculated cost
            if let tracker = usageTracker, let cost = serverCost {
                tracker.record(
                    model: model,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cost: cost
                )
            }
            // Don't show usage notifications in chat — just track silently
            _ = repo // suppress unused warning
        }
    }
}

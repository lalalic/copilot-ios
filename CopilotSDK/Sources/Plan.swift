import Foundation

// MARK: - Plan

/// A named, schedulable task with a prompt and configuration.
public struct Plan: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var prompt: String
    public var schedule: PlanSchedule
    public var model: String
    public var enabled: Bool
    public var requiresApproval: Bool
    public var maxTokenBudget: Int
    public var tools: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String,
        schedule: PlanSchedule,
        model: String = "gpt-4.1",
        enabled: Bool = true,
        requiresApproval: Bool = false,
        maxTokenBudget: Int = 10000,
        tools: [String] = []
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.model = model
        self.enabled = enabled
        self.requiresApproval = requiresApproval
        self.maxTokenBudget = maxTokenBudget
        self.tools = tools
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - PlanSchedule

/// How a plan should be scheduled.
public enum PlanSchedule: Codable, Sendable {
    case manual
    case once(at: Date)
    case interval(seconds: Int)
    case cron(expression: String, timezone: String)

    /// Calculate the next fire date after the given date.
    public func nextFireDate(after: Date = Date()) -> Date? {
        switch self {
        case .manual:
            return nil
        case .once(let at):
            return at > after ? at : nil
        case .interval(let seconds):
            return after.addingTimeInterval(TimeInterval(seconds))
        case .cron:
            // Cron parsing deferred — return nil for now
            return nil
        }
    }
}

// MARK: - PlanExecution

/// Record of a single plan execution.
public struct PlanExecution: Codable, Identifiable, Sendable {
    public let id: String
    public let planId: String
    public let startedAt: Date
    public var completedAt: Date?
    public var status: ExecutionStatus
    public var result: String?
    public var tokensUsed: TokenUsage?
    public var cost: Double?
    public var error: String?

    public enum ExecutionStatus: String, Codable, Sendable {
        case running, completed, failed, cancelled, awaitingApproval
    }

    public struct TokenUsage: Codable, Sendable {
        public var promptTokens: Int
        public var completionTokens: Int

        public init(promptTokens: Int = 0, completionTokens: Int = 0) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
        }
    }

    public init(planId: String, id: String = UUID().uuidString) {
        self.id = id
        self.planId = planId
        self.startedAt = Date()
        self.status = .running
    }

    /// Mark execution as completed.
    public mutating func complete(result: String?, tokensUsed: TokenUsage?, cost: Double?) {
        self.status = .completed
        self.result = result
        self.tokensUsed = tokensUsed
        self.cost = cost
        self.completedAt = Date()
    }

    /// Mark execution as failed.
    public mutating func fail(error: String) {
        self.status = .failed
        self.error = error
        self.completedAt = Date()
    }
}

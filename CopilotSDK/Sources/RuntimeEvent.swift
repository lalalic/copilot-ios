import Foundation

// MARK: - RuntimeEvent

/// Provider-neutral event model for the agent runtime layer.
/// Replaces Copilot wire events as the source of truth for UI state transitions.
public enum RuntimeEvent: Sendable {

    // MARK: - Assistant Text

    /// Incremental text delta from the assistant.
    case assistantTextDelta(AssistantTextDelta)

    /// Assistant message completed (full content).
    case assistantMessageComplete(AssistantMessageComplete)

    // MARK: - Reasoning / Thinking

    /// Incremental reasoning/thinking delta.
    case reasoningDelta(ReasoningDelta)

    /// Reasoning block completed.
    case reasoningComplete(ReasoningComplete)

    // MARK: - Turn Lifecycle

    /// A new assistant turn has started.
    case turnStart(TurnStart)

    /// The current turn has ended.
    case turnEnd(TurnEnd)

    // MARK: - Tool Execution

    /// A tool call has been initiated.
    case toolStart(ToolStart)

    /// Incremental progress update from a running tool.
    case toolUpdate(ToolUpdate)

    /// A tool call has completed.
    case toolComplete(ToolComplete)

    // MARK: - Session State

    /// The session queue state has changed (e.g. prompt enqueued, dequeued).
    case queueStateUpdate(QueueStateUpdate)

    /// Usage/cost information update.
    case usageUpdate(UsageUpdate)

    /// An error occurred in the runtime.
    case error(RuntimeError)

    /// A session has been restored from persistence.
    case sessionRestored(SessionRestored)

    /// Session is idle — no active turns.
    case sessionIdle

    // MARK: - User Interaction

    /// The runtime is requesting user input (e.g. ask_questions).
    case userInputRequested(UserInputRequest)

    /// Context compaction has started.
    case compactionStart

    /// Context compaction has completed.
    case compactionComplete
}

// MARK: - Event Payloads

extension RuntimeEvent {

    public struct AssistantTextDelta: Sendable {
        public let text: String
        public let messageId: String?

        public init(text: String, messageId: String? = nil) {
            self.text = text
            self.messageId = messageId
        }
    }

    public struct AssistantMessageComplete: Sendable {
        public let content: String
        public let messageId: String?
        public let model: String?

        public init(content: String, messageId: String? = nil, model: String? = nil) {
            self.content = content
            self.messageId = messageId
            self.model = model
        }
    }

    public struct ReasoningDelta: Sendable {
        public let text: String
        public let messageId: String?

        public init(text: String, messageId: String? = nil) {
            self.text = text
            self.messageId = messageId
        }
    }

    public struct ReasoningComplete: Sendable {
        public let content: String
        public let messageId: String?

        public init(content: String, messageId: String? = nil) {
            self.content = content
            self.messageId = messageId
        }
    }

    public struct TurnStart: Sendable {
        public let turnId: String

        public init(turnId: String = UUID().uuidString) {
            self.turnId = turnId
        }
    }

    public struct TurnEnd: Sendable {
        public let turnId: String

        public init(turnId: String = UUID().uuidString) {
            self.turnId = turnId
        }
    }

    public struct ToolStart: Sendable {
        public let toolCallId: String
        public let toolName: String
        public let arguments: String?

        public init(toolCallId: String, toolName: String, arguments: String? = nil) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.arguments = arguments
        }
    }

    public struct ToolUpdate: Sendable {
        public let toolCallId: String
        public let progress: String?

        public init(toolCallId: String, progress: String? = nil) {
            self.toolCallId = toolCallId
            self.progress = progress
        }
    }

    public struct ToolComplete: Sendable {
        public let toolCallId: String
        public let toolName: String
        public let result: String?
        public let isError: Bool

        public init(toolCallId: String, toolName: String, result: String? = nil, isError: Bool = false) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.result = result
            self.isError = isError
        }
    }

    public struct QueueStateUpdate: Sendable {
        public let pendingCount: Int

        public init(pendingCount: Int) {
            self.pendingCount = pendingCount
        }
    }

    public struct UsageUpdate: Sendable {
        public let model: String
        public let promptTokens: Int
        public let completionTokens: Int
        public let cost: Double

        public init(model: String, promptTokens: Int, completionTokens: Int, cost: Double) {
            self.model = model
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.cost = cost
        }
    }

    public struct RuntimeError: Sendable {
        public let message: String
        public let code: Int?
        public let isRecoverable: Bool

        public init(message: String, code: Int? = nil, isRecoverable: Bool = true) {
            self.message = message
            self.code = code
            self.isRecoverable = isRecoverable
        }
    }

    public struct SessionRestored: Sendable {
        public let sessionName: String
        public let messageCount: Int

        public init(sessionName: String, messageCount: Int) {
            self.sessionName = sessionName
            self.messageCount = messageCount
        }
    }

    public struct UserInputRequest: Sendable {
        public let requestId: String
        public let questions: [Question]

        public init(requestId: String, questions: [Question]) {
            self.requestId = requestId
            self.questions = questions
        }

        public struct Question: Sendable {
            public let id: String
            public let text: String
            public let options: [String]?
            public let multiSelect: Bool

            public init(id: String, text: String, options: [String]? = nil, multiSelect: Bool = false) {
                self.id = id
                self.text = text
                self.options = options
                self.multiSelect = multiSelect
            }
        }
    }
}



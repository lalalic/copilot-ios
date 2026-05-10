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

// MARK: - RuntimeEvent ↔ SessionEvent Mapping

extension RuntimeEvent {

    /// Map a legacy SessionEvent into a provider-neutral RuntimeEvent.
    /// Returns nil if the event type has no runtime equivalent.
    public static func from(sessionEvent: SessionEvent) -> RuntimeEvent? {
        switch sessionEvent.type {
        case .assistantMessageDelta:
            if case .object(let data) = sessionEvent.data,
               case .string(let delta) = data["delta"] {
                return .assistantTextDelta(.init(text: delta, messageId: sessionEvent.id))
            }

        case .assistantStreamingDelta:
            if case .object(let data) = sessionEvent.data,
               case .string(let delta) = data["delta"] {
                return .assistantTextDelta(.init(text: delta, messageId: sessionEvent.id))
            }

        case .assistantMessage:
            if case .object(let data) = sessionEvent.data,
               case .string(let content) = data["content"] {
                return .assistantMessageComplete(.init(content: content, messageId: sessionEvent.id))
            }

        case .assistantReasoningDelta:
            if case .object(let data) = sessionEvent.data,
               case .string(let delta) = data["delta"] {
                return .reasoningDelta(.init(text: delta, messageId: sessionEvent.id))
            }

        case .assistantReasoning:
            if case .object(let data) = sessionEvent.data,
               case .string(let content) = data["content"] {
                return .reasoningComplete(.init(content: content, messageId: sessionEvent.id))
            }

        case .assistantTurnStart:
            return .turnStart(.init(turnId: sessionEvent.id ?? UUID().uuidString))

        case .assistantTurnEnd:
            return .turnEnd(.init(turnId: sessionEvent.id ?? UUID().uuidString))

        case .sessionIdle:
            return .sessionIdle

        case .toolExecutionStart:
            if case .object(let data) = sessionEvent.data {
                let toolName = data["toolName"]?.stringValue ?? "unknown"
                let toolCallId = data["toolCallId"]?.stringValue ?? UUID().uuidString
                let args = data["arguments"]?.stringValue
                return .toolStart(.init(toolCallId: toolCallId, toolName: toolName, arguments: args))
            }

        case .toolExecutionPartialResult, .toolExecutionProgress:
            if case .object(let data) = sessionEvent.data {
                let toolCallId = data["toolCallId"]?.stringValue ?? UUID().uuidString
                let progress = data["progress"]?.stringValue ?? data["result"]?.stringValue
                return .toolUpdate(.init(toolCallId: toolCallId, progress: progress))
            }

        case .toolExecutionComplete:
            if case .object(let data) = sessionEvent.data {
                let toolCallId = data["toolCallId"]?.stringValue ?? UUID().uuidString
                let toolName = data["toolName"]?.stringValue ?? "unknown"
                let result = data["result"]?.stringValue
                let isError = data["isError"]?.boolValue ?? false
                return .toolComplete(.init(toolCallId: toolCallId, toolName: toolName, result: result, isError: isError))
            }

        case .assistantUsage:
            if case .object(let data) = sessionEvent.data {
                let model = data["model"]?.stringValue ?? "unknown"
                let cost = data["cost"]?.doubleValue ?? 0
                let promptTokens = data["inputTokens"]?.intValue ?? data["prompt_tokens"]?.intValue ?? 0
                let completionTokens = data["outputTokens"]?.intValue ?? data["completion_tokens"]?.intValue ?? 0
                return .usageUpdate(.init(model: model, promptTokens: promptTokens, completionTokens: completionTokens, cost: cost))
            }

        case .sessionError:
            if case .object(let data) = sessionEvent.data,
               case .string(let message) = data["message"] {
                return .error(.init(message: message))
            }

        case .sessionCompactionStart:
            return .compactionStart

        case .sessionCompactionComplete:
            return .compactionComplete

        case .elicitationRequested:
            if case .object(let data) = sessionEvent.data {
                let requestId = data["requestId"]?.stringValue ?? UUID().uuidString
                // Parse questions array from elicitation data
                var questions: [UserInputRequest.Question] = []
                if case .array(let items) = data["questions"] {
                    for item in items {
                        if case .object(let q) = item {
                            let id = q["id"]?.stringValue ?? UUID().uuidString
                            let text = q["question"]?.stringValue ?? q["text"]?.stringValue ?? ""
                            var options: [String]?
                            if case .array(let opts) = q["options"] {
                                options = opts.compactMap { $0.stringValue }
                            }
                            let multi = q["multiSelect"]?.boolValue ?? false
                            questions.append(.init(id: id, text: text, options: options, multiSelect: multi))
                        }
                    }
                }
                return .userInputRequested(.init(requestId: requestId, questions: questions))
            }

        default:
            return nil
        }
        return nil
    }
}

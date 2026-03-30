import Foundation

// MARK: - Todo Item

/// A task in the manage_todo_list tool's todo list.
public struct TodoItem: Identifiable, Sendable, Equatable {
    public let id: Int
    public var title: String
    public var status: Status

    public enum Status: String, Sendable, Equatable {
        case notStarted = "not-started"
        case inProgress = "in-progress"
        case completed = "completed"
    }

    public init(id: Int, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }

    /// Status icon for display.
    public var statusIcon: String {
        switch status {
        case .notStarted: return "○"
        case .inProgress: return "●"
        case .completed: return "✓"
        }
    }
}

// MARK: - Input Mode

/// Configurable input modes for the chat input bar.
public struct InputMode: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Text input via keyboard.
    public static let text = InputMode(rawValue: 1 << 0)
    /// Speech input via microphone.
    public static let speech = InputMode(rawValue: 1 << 1)
    /// File/photo attachment input.
    public static let attachment = InputMode(rawValue: 1 << 2)

    /// All input modes enabled.
    public static let all: InputMode = [.text, .speech, .attachment]
    /// Text and speech (default).
    public static let textAndSpeech: InputMode = [.text, .speech]
}

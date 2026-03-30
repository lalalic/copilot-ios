import Foundation

public struct AskQuestionOption: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let label: String
    public let description: String?
    public let recommended: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        description: String? = nil,
        recommended: Bool = false
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

public struct AskQuestionItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let header: String
    public let question: String
    public let multiSelect: Bool
    public let options: [AskQuestionOption]
    public let allowFreeformInput: Bool

    public init(
        id: UUID = UUID(),
        header: String,
        question: String,
        multiSelect: Bool = false,
        options: [AskQuestionOption] = [],
        allowFreeformInput: Bool = false
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
        self.allowFreeformInput = allowFreeformInput
    }
}

public struct AskQuestionAnswer: Sendable, Equatable {
    public let selected: [String]
    public let freeText: String?
    public let skipped: Bool

    public init(selected: [String] = [], freeText: String? = nil, skipped: Bool = false) {
        self.selected = selected
        self.freeText = freeText
        self.skipped = skipped
    }
}

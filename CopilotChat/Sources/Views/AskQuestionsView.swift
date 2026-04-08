import SwiftUI

public struct AskQuestionsView: View {
    let questions: [AskQuestionItem]
    let onSubmit: ([String: AskQuestionAnswer]) -> Void
    let onSkip: () -> Void

    @State private var selectedByHeader: [String: Set<String>] = [:]
    @State private var freeTextByHeader: [String: String] = [:]
    @State private var expandedHeaders: Set<String> = []

    public init(
        questions: [AskQuestionItem],
        onSubmit: @escaping ([String: AskQuestionAnswer]) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.questions = questions
        self.onSubmit = onSubmit
        self.onSkip = onSkip
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Questions", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Skip") {
                    onSkip()
                }
                .font(.caption)
            }

            ForEach(questions) { item in
                questionCard(item)
            }

            Button {
                onSubmit(buildAnswers())
            } label: {
                Text("Submit Answers")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .onAppear {
            // Auto-expand first question
            if let first = questions.first {
                expandedHeaders.insert(first.header)
            }
        }
    }

    @ViewBuilder
    private func questionCard(_ item: AskQuestionItem) -> some View {
        let isExpanded = expandedHeaders.contains(item.header)
        VStack(alignment: .leading, spacing: 8) {
            // Tappable header — toggles expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedHeaders.contains(item.header) {
                        expandedHeaders.remove(item.header)
                    } else {
                        expandedHeaders.insert(item.header)
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.header)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(item.question)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.options) { option in
                        Button {
                            toggleSelection(option.label, for: item)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isSelected(option.label, for: item)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundStyle(isSelected(option.label, for: item) ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(option.label)
                                            .font(.subheadline)
                                        if option.recommended {
                                            Text("Recommended")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.15))
                                                .foregroundStyle(.blue)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    if let desc = option.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(isSelected(option.label, for: item) ? Color.blue.opacity(0.08) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if item.allowFreeformInput {
                    TextField("Additional input", text: bindingForFreeText(header: item.header), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                }
            }
        }
        .padding(10)
        .background(platformGray6)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func isSelected(_ label: String, for item: AskQuestionItem) -> Bool {
        selectedByHeader[item.header]?.contains(label) == true
    }

    private func toggleSelection(_ label: String, for item: AskQuestionItem) {
        var set = selectedByHeader[item.header] ?? Set<String>()
        if item.multiSelect {
            if set.contains(label) {
                set.remove(label)
            } else {
                set.insert(label)
            }
        } else {
            if set.contains(label) {
                set.removeAll()
            } else {
                set = [label]
            }
        }
        selectedByHeader[item.header] = set
    }

    private func bindingForFreeText(header: String) -> Binding<String> {
        Binding {
            freeTextByHeader[header] ?? ""
        } set: { newValue in
            freeTextByHeader[header] = newValue
        }
    }

    private func buildAnswers() -> [String: AskQuestionAnswer] {
        var result: [String: AskQuestionAnswer] = [:]
        for item in questions {
            let selected = Array(selectedByHeader[item.header] ?? Set<String>())
            let freeText = (freeTextByHeader[item.header] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = AskQuestionAnswer(
                selected: selected,
                freeText: freeText.isEmpty ? nil : freeText,
                skipped: false
            )
            result[item.header] = answer
        }
        return result
    }
}

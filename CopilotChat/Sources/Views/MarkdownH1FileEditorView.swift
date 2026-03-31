import SwiftUI

public struct MarkdownH1FileEditorView: View {
    public let fileURL: URL
    public let navigationTitleText: String
    public let loadingText: String
    public let availableTools: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var document = MarkdownH1Document.empty
    @State private var errorMessage: String?
    @State private var isLoaded = false
    @State private var hasToolsField = false
    @State private var selectedTools: Set<String> = []

    public init(
        fileURL: URL,
        navigationTitleText: String = "Edit Markdown",
        loadingText: String = "Loading...",
        availableTools: [String] = []
    ) {
        self.fileURL = fileURL
        self.navigationTitleText = navigationTitleText
        self.loadingText = loadingText
        self.availableTools = availableTools
    }

    public var body: some View {
        Form {
            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if !isLoaded {
                Section {
                    ProgressView(loadingText)
                }
            } else if hasToolsField && !availableTools.isEmpty {
                Section("Tools") {
                    ForEach(availableTools.sorted(), id: \.self) { tool in
                        Toggle(tool, isOn: Binding(
                            get: { selectedTools.contains(tool) },
                            set: { isEnabled in
                                if isEnabled {
                                    selectedTools.insert(tool)
                                } else {
                                    selectedTools.remove(tool)
                                }
                            }
                        ))
                    }
                }
            }

            if isLoaded && document.sections.isEmpty {
                Section("No H1 Sections") {
                    Text("No '# ' sections found in file")
                        .foregroundStyle(.secondary)
                }
            } else if isLoaded {
                ForEach(document.sections.indices, id: \.self) { index in
                    Section(document.sections[index].title) {
                        TextEditor(text: $document.sections[index].body)
                            .frame(minHeight: 140)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!isLoaded)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            document = MarkdownH1Document.parse(content)
            let toolsInfo = parseTools(from: content)
            hasToolsField = toolsInfo.hasToolsField
            selectedTools = Set(toolsInfo.selected)
            isLoaded = true
        } catch {
            errorMessage = "Failed to load file: \(error.localizedDescription)"
            isLoaded = true
        }
    }

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var output = document.render()
            if hasToolsField {
                output = rewriteTools(in: output, selectedTools: selectedTools.sorted())
            }
            try output.write(to: fileURL, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            errorMessage = "Failed to save file: \(error.localizedDescription)"
        }
    }

    private func parseTools(from raw: String) -> (hasToolsField: Bool, selected: [String]) {
        guard let frontmatter = extractFrontmatter(raw) else {
            return (false, [])
        }

        let lines = frontmatter.components(separatedBy: "\n")
        var hasTools = false
        var tools: [String] = []
        var collectingIndentedList = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tools:") {
                hasTools = true
                collectingIndentedList = true
                let rest = trimmed.replacingOccurrences(of: "tools:", with: "").trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") && rest.hasSuffix("]") {
                    let inner = String(rest.dropFirst().dropLast())
                    tools.append(contentsOf: inner
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty })
                    collectingIndentedList = false
                }
                continue
            }

            if collectingIndentedList {
                if trimmed.hasPrefix("-") {
                    let value = trimmed
                        .replacingOccurrences(of: "-", with: "", options: [], range: trimmed.startIndex..<trimmed.index(after: trimmed.startIndex))
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        tools.append(value)
                    }
                } else if !trimmed.isEmpty {
                    collectingIndentedList = false
                }
            }
        }

        return (hasTools, tools)
    }

    private func rewriteTools(in raw: String, selectedTools: [String]) -> String {
        guard let (range, frontmatter) = extractFrontmatterWithRange(raw) else {
            return raw
        }

        let lines = frontmatter.components(separatedBy: "\n")
        var rewritten: [String] = []
        var index = 0
        var replaced = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tools:") {
                let toolsValue = selectedTools.joined(separator: ", ")
                rewritten.append("tools: [\(toolsValue)]")
                replaced = true
                index += 1
                while index < lines.count {
                    let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("-") {
                        index += 1
                    } else {
                        break
                    }
                }
                continue
            }
            rewritten.append(line)
            index += 1
        }

        if !replaced {
            return raw
        }

        let rebuiltFrontmatter = "---\n" + rewritten.joined(separator: "\n") + "\n---"
        var updated = raw
        updated.replaceSubrange(range, with: rebuiltFrontmatter)
        return updated
    }

    private func extractFrontmatter(_ raw: String) -> String? {
        guard let (_, frontmatter) = extractFrontmatterWithRange(raw) else { return nil }
        return frontmatter
    }

    private func extractFrontmatterWithRange(_ raw: String) -> (Range<String.Index>, String)? {
        guard raw.hasPrefix("---\n") else { return nil }
        let searchStart = raw.index(raw.startIndex, offsetBy: 4)
        guard let closeRange = raw.range(of: "\n---", range: searchStart..<raw.endIndex) else {
            return nil
        }
        let fullRange = raw.startIndex..<closeRange.upperBound
        let frontmatterStart = searchStart
        let frontmatterEnd = closeRange.lowerBound
        return (fullRange, String(raw[frontmatterStart..<frontmatterEnd]))
    }
}

private struct MarkdownH1Document {
    struct Section {
        var header: String
        var body: String

        var title: String {
            header
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "# ", with: "")
        }
    }

    var prefix: String
    var sections: [Section]

    static var empty: MarkdownH1Document {
        MarkdownH1Document(prefix: "", sections: [])
    }

    static func parse(_ raw: String) -> MarkdownH1Document {
        let lines = raw.components(separatedBy: "\n")
        var sections: [Section] = []

        var firstHeaderIndex: Int?
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("# ") {
                firstHeaderIndex = index
                break
            }
        }

        guard let firstHeaderIndex else {
            return MarkdownH1Document(prefix: raw, sections: [])
        }

        let prefix = lines[..<firstHeaderIndex].joined(separator: "\n")
        var cursor = firstHeaderIndex

        while cursor < lines.count {
            guard lines[cursor].hasPrefix("# ") else {
                cursor += 1
                continue
            }

            let header = lines[cursor]
            var nextHeader = cursor + 1
            while nextHeader < lines.count && !lines[nextHeader].hasPrefix("# ") {
                nextHeader += 1
            }

            let bodyStart = cursor + 1
            let body = bodyStart < nextHeader
                ? lines[bodyStart..<nextHeader].joined(separator: "\n")
                : ""

            sections.append(Section(header: header, body: body))
            cursor = nextHeader
        }

        return MarkdownH1Document(prefix: prefix, sections: sections)
    }

    func render() -> String {
        var chunks: [String] = []

        if !prefix.isEmpty {
            chunks.append(prefix)
        }

        for section in sections {
            chunks.append(section.header)
            if !section.body.isEmpty {
                chunks.append(section.body)
            }
        }

        return chunks.joined(separator: "\n") + "\n"
    }
}

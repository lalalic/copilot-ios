import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Markdown View

/// Renders markdown text using iOS 15+ `AttributedString(markdown:)`.
/// Supports headings, bold, italic, links, inline code, and lists.
public struct MarkdownView: View {

    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Code Block View

/// Renders a code block with monospace font, background, and copy button.
public struct CodeBlockView: View {

    private let code: String
    private let language: String?
    @State private var copied = false

    public init(code: String, language: String? = nil) {
        self.code = code
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label and copy button
            HStack {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToClipboard()
                } label: {
                    Label(
                        copied ? "Copied" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(platformGray5)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(platformGray6)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyToClipboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { copied = false }
        }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Message Bubble

/// Renders a single chat message with role-based styling.
/// Handles all content block types: text, markdown, code, mermaid, image, attachment.
public struct MessageBubble: View {

    private let message: ChatMessage

    public init(message: ChatMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant || message.role == .system {
                avatar
                VStack(alignment: .leading, spacing: 6) {
                    contentBlocks
                    if message.isStreaming {
                        streamingIndicator
                    }
                }
                Spacer(minLength: 40)
            } else {
                // User message — right-aligned
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    contentBlocks
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Avatar

    private var avatar: some View {
        Group {
            switch message.role {
            case .assistant:
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.purple.opacity(0.15)))
            case .system:
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Content Blocks

    private var contentBlocks: some View {
        ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
            contentView(for: block)
        }
    }

    @ViewBuilder
    private func contentView(for block: ChatMessage.ContentBlock) -> some View {
        switch block {
        case .text(let text):
            textBubble(text)

        case .markdown(let text):
            markdownBubble(text)

        case .code(let code, let language):
            CodeBlockView(code: code, language: language)

        case .mermaid(let source):
            HStack {
                Spacer(minLength: 0)
                MermaidView(source: source)
                    .frame(maxWidth: 320, minHeight: 200)
                Spacer(minLength: 0)
            }

        case .image(let data, _):
            #if canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            #endif

        case .attachment(_, let name):
            attachmentChip(name: name)
        }
    }

    // MARK: - Bubble Styles

    private func textBubble(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func markdownBubble(_ text: String) -> some View {
        MarkdownView(text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func attachmentChip(name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 14))
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(platformGray5)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return Color.blue
        case .assistant:
            return platformGray6
        case .system:
            return Color.orange.opacity(0.15)
        case .tool:
            return platformGray6
        }
    }

    private var streamingIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(0.4)
            }
        }
        .padding(.leading, 12)
    }
}

// MARK: - User Message Text Color

extension MessageBubble {
    /// User messages use white text on blue background.
    fileprivate var textColor: Color {
        message.role == .user ? .white : .primary
    }
}

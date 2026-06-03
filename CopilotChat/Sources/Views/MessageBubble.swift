import SwiftUI
import AVFoundation
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
    private let uploadingAttachments: Set<String>
    private let failedAttachments: Set<String>

    public init(message: ChatMessage, uploadingAttachments: Set<String> = [], failedAttachments: Set<String> = []) {
        self.message = message
        self.uploadingAttachments = uploadingAttachments
        self.failedAttachments = failedAttachments
    }

    public var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
            if let source = message.source {
                sourceBadge(source)
            }
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let prefix = message.source.map { "\($0): " } ?? ""
        let body = message.content.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .markdown(let t): return t
            case .code(let c, _): return c
            default: return nil
            }
        }.joined(separator: " ")
        return prefix + body
    }

    // MARK: - Source Badge

    private func sourceBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
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
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(platformGray6))
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

        case .attachment(let url, let name, let mimeType):
            if mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/") {
                BubbleMediaThumb(url: url, mimeType: mimeType)
                    .overlay {
                        if uploadingAttachments.contains(name) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.black.opacity(0.35))
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            }
                            .frame(width: 56, height: 56)
                        } else if failedAttachments.contains(name) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.black.opacity(0.35))
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.red)
                            }
                            .frame(width: 56, height: 56)
                        }
                    }
            } else {
                attachmentChip(name: name)
                    .overlay {
                        if uploadingAttachments.contains(name) {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else if failedAttachments.contains(name) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                    }
            }
        }
    }

    // MARK: - Bubble Styles

    private func textBubble(_ text: String) -> some View {
        let textColor: Color = message.role == .system ? .secondary : (message.role == .user ? .white : .primary)
        return Text(text)
            .font(message.role == .system ? .caption : .body)
            .foregroundStyle(textColor)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func markdownBubble(_ text: String) -> some View {
        let textColor: Color = message.role == .system ? .secondary : .primary
        return MarkdownView(text)
            .font(message.role == .system ? .caption : .body)
            .foregroundStyle(textColor)
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
            return platformGray6.opacity(0.7)
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

// MARK: - Bubble Media Thumbnail

#if canImport(UIKit)
private struct BubbleMediaThumb: View {
    let url: URL
    let mimeType: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        if mimeType.hasPrefix("video/") {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.6), in: Circle())
                                .padding(3)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: mimeType.hasPrefix("video/") ? "video" : "photo")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 16))
                    }
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        let u = url
        let mime = mimeType
        let img: UIImage? = await Task.detached { () -> UIImage? in
            // Persisted thumbnails are JPEGs — try decoding as image first
            // regardless of mimeType. Fall back to video frame extraction only
            // when the file is not a decodable image (e.g., raw video URL).
            if let data = try? Data(contentsOf: u), let i = UIImage(data: data) {
                return i
            }
            if mime.hasPrefix("video/") {
                let asset = AVURLAsset(url: u)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 400, height: 400)
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                    return UIImage(cgImage: cg)
                }
            }
            return nil
        }.value
        if let img { self.image = img }
    }
}
#else
private struct BubbleMediaThumb: View {
    let url: URL
    let mimeType: String
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.3))
            .frame(width: 56, height: 56)
    }
}
#endif

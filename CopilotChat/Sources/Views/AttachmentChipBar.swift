import SwiftUI
import CopilotSDK

// MARK: - Attachment Chip Bar

/// Horizontal strip of chips showing staged attachments.
/// Each chip shows the file name and a dismiss button.
struct AttachmentChipBar: View {

    let store: AttachmentStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    AttachmentChip(entry: entry) {
                        store.remove(at: index)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Attachment Chip

/// A single attachment chip with icon, name, and close button.
private struct AttachmentChip: View {

    let entry: AttachmentEntry
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(entry.displayName)
                .font(.caption)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(.systemGray5))
        )
    }

    private var iconName: String {
        let mime = entry.mimeType
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "video" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

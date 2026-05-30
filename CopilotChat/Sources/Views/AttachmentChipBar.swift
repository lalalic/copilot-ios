import SwiftUI
import AVFoundation
import CopilotSDK
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Attachment Chip Bar

/// Horizontal strip of chips showing staged attachments.
/// For image / video attachments, the chip shows a small thumbnail; other
/// types fall back to an icon + filename.
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

private struct AttachmentChip: View {

    let entry: AttachmentEntry
    let onRemove: () -> Void

    var body: some View {
        if isMedia {
            mediaThumb
        } else {
            fileChip
        }
    }

    private var isMedia: Bool {
        entry.mimeType.hasPrefix("image/") || entry.mimeType.hasPrefix("video/")
    }

    @ViewBuilder
    private var mediaThumb: some View {
        ZStack(alignment: .topTrailing) {
            ThumbnailView(entry: entry)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if entry.mimeType.hasPrefix("video/") {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(3)
                    }
                }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }

    @ViewBuilder
    private var fileChip: some View {
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
        .background(Capsule().fill(Color(.systemGray5)))
    }

    private var iconName: String {
        let mime = entry.mimeType
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

// MARK: - Thumbnail

#if canImport(UIKit)
private struct ThumbnailView: View {
    let entry: AttachmentEntry
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .overlay {
                        Image(systemName: entry.mimeType.hasPrefix("video/") ? "video" : "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: entry.id) {
            await load()
        }
    }

    private func load() async {
        let url = entry.fileURL
        let mime = entry.mimeType
        let img: UIImage? = await Task.detached { () -> UIImage? in
            if mime.hasPrefix("video/") {
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 200, height: 200)
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                    return UIImage(cgImage: cg)
                }
                return nil
            }
            if let data = try? Data(contentsOf: url) {
                return UIImage(data: data)
            }
            return nil
        }.value
        if let img { self.image = img }
    }
}
#else
private struct ThumbnailView: View {
    let entry: AttachmentEntry
    var body: some View { Color.gray }
}
#endif

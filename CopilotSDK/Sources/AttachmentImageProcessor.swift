import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Downsizes image / video attachments before upload or vision processing.
/// Non-media files are left untouched.
public enum AttachmentImageProcessor {

    /// Max side length (in pixels) for staged images. 1080p target.
    public static let maxDimension: CGFloat = 1080
    /// Max side length for staged videos. 720p target — keeps file sizes
    /// reasonable for upload while still giving the vision model usable frames.
    public static let maxVideoDimension: CGFloat = 720
    /// JPEG quality for re-encoded images.
    public static let jpegQuality: CGFloat = 0.85

    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tiff", "tif", "gif"]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "qt", "avi", "mkv"]

    /// Shrink an image or video at `url` to ≤ 1080p. Falls back to original URL
    /// if shrinking is not applicable / fails.
    public static func process(at url: URL) async -> URL {
        let ext = url.pathExtension.lowercased()
        if imageExts.contains(ext) {
            return shrinkIfImage(at: url) ?? url
        }
        if videoExts.contains(ext) {
            return (try? await shrinkVideo(at: url)) ?? url
        }
        return url
    }

    /// If `url` points to an image, write a downscaled JPEG to a sibling temp file
    /// and return its URL. Returns `nil` if no shrinking was performed (or platform
    /// lacks UIKit) — caller should fall back to the original URL.
    public static func shrinkIfImage(at url: URL) -> URL? {
        #if canImport(UIKit)
        let ext = url.pathExtension.lowercased()
        guard imageExts.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }

        let size = image.size
        let maxSide = max(size.width, size.height)
        let scale: CGFloat = maxSide > maxDimension ? (maxDimension / maxSide) : 1.0
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))

        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: jpegQuality) else { return nil }

        let baseName = (url.lastPathComponent as NSString).deletingPathExtension
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName)-resized.jpg")
        try? FileManager.default.removeItem(at: outURL)
        do { try jpeg.write(to: outURL) } catch { return nil }
        return outURL
        #else
        return nil
        #endif
    }

    /// Re-encode a video at ≤1080p (longest side). Skips if already smaller.
    public static func shrinkVideo(at url: URL) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(preferredTransform)
        let w = abs(displaySize.width), h = abs(displaySize.height)
        // Already ≤720p on the long side — no re-encode needed.
        if max(w, h) <= maxVideoDimension { return nil }

        let preset = AVAssetExportPreset1280x720
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        guard compatiblePresets.contains(preset),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }

        let baseName = (url.lastPathComponent as NSString).deletingPathExtension
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName)-720p.mp4")
        try? FileManager.default.removeItem(at: outURL)

        session.outputURL = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        guard session.status == .completed else { return nil }
        return outURL
    }
}

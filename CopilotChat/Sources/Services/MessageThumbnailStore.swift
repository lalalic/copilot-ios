import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Generates and persists small JPEG thumbnails for chat message attachments.
/// Lives under `<workspace>/.neo/reports/sessions/thumbs/`. Survives app restart
/// so message bubbles can render media thumbnails after a reload.
public enum MessageThumbnailStore {

    /// Max thumbnail edge length, in pixels.
    public static let maxDimension: CGFloat = 320

    /// Returns the directory thumbnails are stored under. Creates it if missing.
    public static func directory(workspaceURL: URL) -> URL {
        let dir = workspaceURL.appendingPathComponent(".neo/reports/sessions/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generate a persistent JPEG thumbnail for `sourceURL` and return its file URL.
    /// Returns nil when no UIImage backend is available or for unsupported types.
    public static func makeThumbnail(sourceURL: URL, mimeType: String, workspaceURL: URL) -> URL? {
        #if canImport(UIKit)
        let image: UIImage?
        if mimeType.hasPrefix("image/") {
            if let data = try? Data(contentsOf: sourceURL) {
                image = UIImage(data: data)
            } else {
                image = nil
            }
        } else if mimeType.hasPrefix("video/") {
            let asset = AVURLAsset(url: sourceURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxDimension * 2, height: maxDimension * 2)
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                image = UIImage(cgImage: cg)
            } else {
                image = nil
            }
        } else {
            image = nil
        }
        guard let img = image else { return nil }

        let scaled = resize(img, max: maxDimension)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.75) else { return nil }

        let outURL = directory(workspaceURL: workspaceURL)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: outURL)
            return outURL
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    private static func resize(_ image: UIImage, max: CGFloat) -> UIImage {
        let s = image.size
        let longSide = Swift.max(s.width, s.height)
        guard longSide > max else { return image }
        let scale = max / longSide
        let target = CGSize(width: floor(s.width * scale), height: floor(s.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
    #endif
}

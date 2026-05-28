import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Downsizes image attachments before they are staged in the AttachmentStore.
/// Non-image files are left untouched.
enum AttachmentImageProcessor {

    /// Max side length (in pixels) for staged images.
    static let maxDimension: CGFloat = 2048
    /// JPEG quality for re-encoded images.
    static let jpegQuality: CGFloat = 0.85

    /// If `url` points to an image, write a downscaled JPEG to a sibling temp file
    /// and return its URL. Returns `nil` if no shrinking was performed (or platform
    /// lacks UIKit) — caller should fall back to the original URL.
    static func shrinkIfImage(at url: URL) -> URL? {
        #if canImport(UIKit)
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tiff", "tif", "gif"]
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
}

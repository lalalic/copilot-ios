import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - AttachmentError

/// Errors thrown by AttachmentStore operations.
public enum AttachmentError: Error, CustomStringConvertible {
    case notFound(String)
    case readFailed(String)
    
    public var description: String {
        switch self {
        case .notFound(let name): return "Attachment not found: \(name)"
        case .readFailed(let name): return "Failed to read attachment: \(name)"
        }
    }
}

// MARK: - AttachmentEntry

/// Metadata about a single attachment file (lazy — data loaded on demand).
public struct AttachmentEntry: Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let mimeType: String
    public let fileSize: Int
    public let fileURL: URL
    
    public init(id: UUID = UUID(), displayName: String, mimeType: String, fileSize: Int, fileURL: URL) {
        self.id = id
        self.displayName = displayName
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.fileURL = fileURL
    }
}

// MARK: - AttachmentStore

/// Per-session, in-memory registry of attached files.
/// Files are registered eagerly (metadata only) but data is loaded lazily
/// via `loadData(name:)` — typically called by the `get_attachment` tool.
public final class AttachmentStore: @unchecked Sendable {
    
    /// All current attachment entries.
    public private(set) var entries: [AttachmentEntry] = []
    
    public init() {}
    
    // MARK: - Add / Remove / Clear
    
    /// Register a file URL. Reads metadata (size, extension) but NOT the file contents.
    /// Deduplicates display names by appending "-N" suffix.
    @discardableResult
    public func add(url: URL) -> AttachmentEntry {
        let originalName = url.lastPathComponent
        let ext = url.pathExtension
        let baseName = ext.isEmpty ? originalName : String(originalName.dropLast(ext.count + 1))
        
        // Deduplicate names
        let existingNames = Set(entries.map(\.displayName))
        var displayName = originalName
        if existingNames.contains(displayName) {
            var counter = 2
            while true {
                let candidate = ext.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(ext)"
                if !existingNames.contains(candidate) {
                    displayName = candidate
                    break
                }
                counter += 1
            }
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let mime = Self.mimeType(for: ext.lowercased())
        
        let entry = AttachmentEntry(
            displayName: displayName,
            mimeType: mime,
            fileSize: fileSize,
            fileURL: url
        )
        entries.append(entry)
        return entry
    }
    
    /// Remove attachment at the given index.
    public func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }
    
    /// Remove all attachments.
    public func clear() {
        entries.removeAll()
    }
    
    // MARK: - Prompt Description
    
    /// Generate a description to inject into the user prompt.
    /// Returns `nil` if there are no attachments.
    ///
    /// Format:
    /// ```
    /// [Attached files — use `view` tool to see images]
    /// 1. notes.txt (text/plain, 1.2 KB)
    /// 2. photo.jpg (image/jpeg, 245.7 KB)
    /// ```
    public func promptDescription() -> String? {
        guard !entries.isEmpty else { return nil }
        
        var lines = ["[Attached files — use `view` tool to see images]"]
        for (i, entry) in entries.enumerated() {
            let sizeStr = Self.formatFileSize(entry.fileSize)
            lines.append("\(i + 1). \(entry.displayName) (\(entry.mimeType), \(sizeStr))")
        }
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Load Data
    
    /// Load the actual file data for the given display name.
    /// Called by the `get_attachment` tool handler.
    public func loadData(name: String) throws -> (Data, String) {
        guard let entry = entries.first(where: { $0.displayName == name }) else {
            throw AttachmentError.notFound(name)
        }
        guard let data = try? Data(contentsOf: entry.fileURL) else {
            throw AttachmentError.readFailed(name)
        }
        return (data, entry.mimeType)
    }
    
    // MARK: - MIME Type
    
    /// Map common file extensions to MIME types.
    public static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        // Images
        case "jpg", "jpeg":     return "image/jpeg"
        case "png":             return "image/png"
        case "gif":             return "image/gif"
        case "webp":            return "image/webp"
        case "heic", "heif":    return "image/heic"
        case "svg":             return "image/svg+xml"
        case "bmp":             return "image/bmp"
        case "tiff", "tif":     return "image/tiff"
            
        // Video
        case "mp4":             return "video/mp4"
        case "mov":             return "video/quicktime"
        case "avi":             return "video/x-msvideo"
        case "webm":            return "video/webm"
            
        // Audio
        case "mp3":             return "audio/mpeg"
        case "wav":             return "audio/wav"
        case "m4a":             return "audio/mp4"
        case "aac":             return "audio/aac"
            
        // Documents
        case "pdf":             return "application/pdf"
        case "doc":             return "application/msword"
        case "docx":            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":             return "application/vnd.ms-excel"
        case "xlsx":            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":             return "application/vnd.ms-powerpoint"
        case "pptx":            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            
        // Text / Code
        case "txt":             return "text/plain"
        case "md", "markdown":  return "text/markdown"
        case "html", "htm":     return "text/html"
        case "css":             return "text/css"
        case "js":              return "text/javascript"
        case "ts":              return "text/typescript"
        case "json":            return "application/json"
        case "jsonl":           return "application/jsonl"
        case "xml":             return "text/xml"
        case "yaml", "yml":     return "text/yaml"
        case "swift":           return "text/x-swift"
        case "py":              return "text/x-python"
        case "rb":              return "text/x-ruby"
        case "java":            return "text/x-java"
        case "c":               return "text/x-c"
        case "cpp", "cc":       return "text/x-c++src"
        case "h":               return "text/x-c-header"
        case "go":              return "text/x-go"
        case "rs":              return "text/x-rust"
        case "sh", "bash":      return "text/x-shellscript"
        case "csv":             return "text/csv"
            
        // Archives
        case "zip":             return "application/zip"
        case "tar":             return "application/x-tar"
        case "gz":              return "application/gzip"
            
        default:                return "application/octet-stream"
        }
    }
    
    // MARK: - Helpers
    
    private static func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }
    
    // MARK: - Smart Loading
    
    /// Load attachment data with smart processing based on file type.
    /// - Images: auto-resized to maxDimension px
    /// - PDFs: text extracted (first N pages)
    /// - Videos: metadata returned (duration, resolution)
    /// - Text files: returned as-is
    /// - Other: raw base64
    public func loadSmart(name: String, maxImageDimension: Int = 1024) async throws -> SmartAttachmentResult {
        guard let entry = entries.first(where: { $0.displayName == name }) else {
            throw AttachmentError.notFound(name)
        }
        
        let mime = entry.mimeType
        
        // Image: resize and return
        if mime.hasPrefix("image/") {
            return try loadSmartImage(entry: entry, maxDimension: maxImageDimension)
        }
        
        // PDF: extract text
        if mime == "application/pdf" {
            return try loadSmartPDF(entry: entry)
        }
        
        // Video: return metadata
        if mime.hasPrefix("video/") {
            return try await loadSmartVideo(entry: entry)
        }
        
        // Text: return content directly
        if mime.hasPrefix("text/") || Self.isTextMimeType(mime) {
            guard let data = try? Data(contentsOf: entry.fileURL),
                  let text = String(data: data, encoding: .utf8) else {
                throw AttachmentError.readFailed(name)
            }
            return .text(text)
        }
        
        // Binary: return raw data
        guard let data = try? Data(contentsOf: entry.fileURL) else {
            throw AttachmentError.readFailed(name)
        }
        return .binary(data, mimeType: mime)
    }
    
    // MARK: - Smart Image
    
    private func loadSmartImage(entry: AttachmentEntry, maxDimension: Int) throws -> SmartAttachmentResult {
        #if canImport(UIKit)
        guard let data = try? Data(contentsOf: entry.fileURL),
              let image = UIImage(data: data) else {
            throw AttachmentError.readFailed(entry.displayName)
        }
        
        let size = image.size
        let maxSide = max(size.width, size.height)
        
        // If already small enough, return original
        if maxSide <= CGFloat(maxDimension) {
            return .image(data, mimeType: entry.mimeType, width: Int(size.width), height: Int(size.height))
        }
        
        // Resize
        let scale = CGFloat(maxDimension) / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.jpegData(withCompressionQuality: 0.85) { context in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        
        return .image(resized, mimeType: "image/jpeg", width: Int(newSize.width), height: Int(newSize.height))
        #else
        let data = try Data(contentsOf: entry.fileURL)
        return .binary(data, mimeType: entry.mimeType)
        #endif
    }
    
    // MARK: - Smart PDF
    
    private func loadSmartPDF(entry: AttachmentEntry) throws -> SmartAttachmentResult {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: entry.fileURL) else {
            throw AttachmentError.readFailed(entry.displayName)
        }
        
        let pageCount = document.pageCount
        let maxPages = min(pageCount, 10) // Extract first 10 pages
        var textContent = ""
        
        for i in 0..<maxPages {
            if let page = document.page(at: i), let text = page.string {
                if !textContent.isEmpty { textContent += "\n\n" }
                textContent += "--- Page \(i + 1) ---\n"
                textContent += text
            }
        }
        
        if pageCount > maxPages {
            textContent += "\n\n[... \(pageCount - maxPages) more pages not shown]"
        }
        
        return .pdfText(textContent, pageCount: pageCount)
        #else
        let data = try Data(contentsOf: entry.fileURL)
        return .binary(data, mimeType: entry.mimeType)
        #endif
    }
    
    // MARK: - Smart Video
    
    private func loadSmartVideo(entry: AttachmentEntry) async throws -> SmartAttachmentResult {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: entry.fileURL)
        
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        var width = 0
        var height = 0
        if let track = videoTracks.first {
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)
            width = Int(abs(transformedSize.width))
            height = Int(abs(transformedSize.height))
        }
        
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty
        
        // Generate thumbnail
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        
        let thumbTime = CMTime(seconds: min(1.0, max(duration / 2, 0)), preferredTimescale: 600)
        if let cgImage = try await generateThumbnailImage(generator: generator, at: thumbTime) {
            #if canImport(UIKit)
            let uiImage = UIImage(cgImage: cgImage)
            let thumbnailData = uiImage.jpegData(compressionQuality: 0.7)
            #else
            let thumbnailData: Data? = nil
            #endif
            return .videoMetadata(
                duration: duration,
                width: width,
                height: height,
                hasAudio: hasAudio,
                thumbnail: thumbnailData
            )
        } else {
            return .videoMetadata(
                duration: duration,
                width: width,
                height: height,
                hasAudio: hasAudio,
                thumbnail: nil
            )
        }
        #else
        return .binary(Data(), mimeType: entry.mimeType)
        #endif
    }

    #if canImport(AVFoundation)
    private func generateThumbnailImage(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage? {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: cgImage)
            }
        }
    }
    #endif
    
    // MARK: - Thumbnail
    
    /// Generate a small thumbnail for an image attachment (for UI preview).
    public func thumbnail(for name: String, maxDimension: Int = 80) -> Data? {
        #if canImport(UIKit)
        guard let entry = entries.first(where: { $0.displayName == name }),
              entry.mimeType.hasPrefix("image/"),
              let data = try? Data(contentsOf: entry.fileURL),
              let image = UIImage(data: data) else {
            return nil
        }
        
        let size = image.size
        let scale = CGFloat(maxDimension) / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.jpegData(withCompressionQuality: 0.6) { context in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #else
        return nil
        #endif
    }
    
    private static func isTextMimeType(_ mime: String) -> Bool {
        mime == "application/json" || mime == "application/jsonl" || mime == "application/xml" || mime.hasPrefix("text/")
    }
}

// MARK: - Smart Attachment Result

/// Result of smart attachment loading with type-specific data.
public enum SmartAttachmentResult: Sendable {
    /// Plain text content.
    case text(String)
    /// Image data (possibly resized) with dimensions.
    case image(Data, mimeType: String, width: Int, height: Int)
    /// Extracted text from PDF with page count.
    case pdfText(String, pageCount: Int)
    /// Video metadata with optional thumbnail.
    case videoMetadata(duration: Double, width: Int, height: Int, hasAudio: Bool, thumbnail: Data?)
    /// Raw binary data.
    case binary(Data, mimeType: String)
    
    /// Convert to a string suitable for the model.
    public var modelDescription: String {
        switch self {
        case .text(let content):
            return content
        case .image(let data, let mime, let w, let h):
            let base64 = data.base64EncodedString()
            return "[\(w)×\(h) image]\ndata:\(mime);base64,\(base64)"
        case .pdfText(let text, let pages):
            return "[PDF, \(pages) pages]\n\(text)"
        case .videoMetadata(let dur, let w, let h, let audio, let thumb):
            var desc = "[Video: \(w)×\(h), \(String(format: "%.1f", dur))s"
            if audio { desc += ", has audio" }
            desc += "]"
            if let thumb {
                desc += "\nThumbnail: data:image/jpeg;base64,\(thumb.base64EncodedString())"
            }
            return desc
        case .binary(let data, let mime):
            return "[\(mime)] base64:\(data.base64EncodedString())"
        }
    }
}

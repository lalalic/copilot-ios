import Foundation
import os.log

private let log = Logger(subsystem: "com.copilot-ios", category: "AttachmentProcessor")

// MARK: - Processed Attachment

/// The result of preprocessing an attachment for a specific runtime.
/// Runtimes consume these instead of raw `RuntimeAttachment` values.
public struct ProcessedAttachment: Sendable {
    public let name: String
    public let mimeType: String
    public let size: Int

    /// Local file URL (always set — points to the shrunk file on disk).
    public let fileURL: URL

    /// Remote CDN URL (set by desktop processor after upload; nil for local-only).
    public let remoteURL: String?

    /// In-memory bytes — only populated when the runtime needs them
    /// (e.g. base64 vision). Empty otherwise.
    public let data: Data

    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var isVideo: Bool { mimeType.hasPrefix("video/") }
    public var isMedia: Bool { isImage || isVideo }
}

// MARK: - AttachmentProcessor Protocol

/// Per-runtime preprocessing of attachments.
///
/// Each runtime provides its own processor that decides:
/// - Whether to shrink images/videos
/// - Whether to upload to CDN (desktop) or keep local (agent)
/// - What data shape the runtime's `send()` method needs
///
/// Called by `ChatViewModel` after snapshotting and before `runtime.send()`.
public protocol AttachmentProcessor: Sendable {
    /// Process a batch of raw attachments into runtime-specific form.
    /// May shrink, upload, or simply pass through.
    func process(_ attachments: [RuntimeAttachment]) async throws -> [ProcessedAttachment]
}

// MARK: - DesktopAttachmentProcessor

/// Preprocessor for `NeoDesktopRuntime`:
/// 1. Shrink images to ≤1080p, videos to ≤720p
/// 2. Upload media to CDN via `RelayCDNUploader`
/// 3. Return `ProcessedAttachment` with `remoteURL` set
///
/// Non-media attachments are passed through with local URLs only.
public final class DesktopAttachmentProcessor: AttachmentProcessor, @unchecked Sendable {

    private let cdnUploader: RelayCDNUploader

    public init(relayBaseURL: URL, credentialStore: CredentialStore = CredentialStore()) {
        self.cdnUploader = RelayCDNUploader(relayBaseURL: relayBaseURL, credentialStore: credentialStore)
    }

    public func process(_ attachments: [RuntimeAttachment]) async throws -> [ProcessedAttachment] {
        var results: [ProcessedAttachment] = []
        for att in attachments {
            let sourceURL = att.fileURL ?? writeToTemp(att)

            if att.isMedia {
                // Shrink
                let shrunk = await AttachmentImageProcessor.process(at: sourceURL)
                let shrunkSize = fileSize(shrunk)

                // Upload to CDN
                let url = try await cdnUploader.upload(
                    fileURL: shrunk,
                    filename: att.name,
                    mimeType: att.mimeType
                )
                results.append(ProcessedAttachment(
                    name: att.name,
                    mimeType: att.mimeType,
                    size: shrunkSize,
                    fileURL: shrunk,
                    remoteURL: url,
                    data: Data()
                ))
            } else {
                // Non-media: pass through (text, PDF, etc.)
                results.append(ProcessedAttachment(
                    name: att.name,
                    mimeType: att.mimeType,
                    size: att.size,
                    fileURL: sourceURL,
                    remoteURL: nil,
                    data: Data()
                ))
            }
        }
        return results
    }

    private func writeToTemp(_ att: RuntimeAttachment) -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoatt-\(UUID().uuidString)-\(att.name)")
        try? att.data.write(to: tmp)
        return tmp
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

// MARK: - DirectAttachmentProcessor

/// Preprocessor for `DirectProviderRuntime` (agent / BYOK mode):
/// 1. Shrink images to ≤1080p, videos to ≤720p
/// 2. Keep files local (no upload)
/// 3. For images, load data so the runtime can base64-encode for vision APIs
///
/// Files stay on disk — the `get_attachment` tool serves them to the model.
public final class DirectAttachmentProcessor: AttachmentProcessor, @unchecked Sendable {

    public init() {}

    public func process(_ attachments: [RuntimeAttachment]) async throws -> [ProcessedAttachment] {
        var results: [ProcessedAttachment] = []
        for att in attachments {
            let sourceURL = att.fileURL ?? writeToTemp(att)

            // Shrink media
            let processed: URL
            if att.isMedia {
                processed = await AttachmentImageProcessor.process(at: sourceURL)
            } else {
                processed = sourceURL
            }
            let size = fileSize(processed)

            // For images, load data so DirectProviderRuntime can send as vision
            let data: Data
            if att.isImage {
                data = (try? Data(contentsOf: processed)) ?? Data()
            } else {
                data = Data()
            }

            results.append(ProcessedAttachment(
                name: att.name,
                mimeType: att.mimeType,
                size: size,
                fileURL: processed,
                remoteURL: nil,
                data: data
            ))
        }
        return results
    }

    private func writeToTemp(_ att: RuntimeAttachment) -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoatt-\(UUID().uuidString)-\(att.name)")
        try? att.data.write(to: tmp)
        return tmp
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

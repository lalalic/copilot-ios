import Foundation
import os.log

private let logger = Logger(subsystem: "com.copilot-ios.sdk", category: "DownloadTools")

/// Provides a `download_file` tool that lets an AI agent download files from the internet
/// and save them to the on-device workspace. Uses URLSession for network requests.
/// All destination paths are sandboxed under the workspace directory.
public final class DownloadToolProvider: Sendable {

    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public var tools: [ToolDefinition] {
        [downloadFileTool]
    }

    // MARK: - Path Resolution

    private func resolve(_ path: String) -> URL? {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "../", with: "")
        let resolved = baseDirectory.appendingPathComponent(cleaned).standardized
        guard resolved.path.hasPrefix(baseDirectory.path) else { return nil }
        return resolved
    }

    // MARK: - download_file

    private var downloadFileTool: ToolDefinition {
        ToolDefinition(
            name: "download_file",
            description: "Download a file from a URL and save it to the workspace. Supports any file type (mp3, mp4, json, images, etc.). Returns the saved file path and size.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The URL to download from")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative destination path in workspace, e.g. 'music/bgm-sample.mp3'")
                    ])
                ]),
                "required": .array([.string("url"), .string("path")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: DownloadToolProvider not available" }
            guard case .object(let dict) = args,
                  case .string(let urlString) = dict["url"],
                  case .string(let path) = dict["path"] else {
                return "Error: 'url' (string) and 'path' (string) required"
            }
            guard let url = URL(string: urlString) else {
                return "Error: invalid URL '\(urlString)'"
            }
            guard url.scheme == "http" || url.scheme == "https" else {
                return "Error: only http/https URLs are supported"
            }
            guard let destURL = self.resolve(path) else {
                return "Error: invalid destination path '\(path)'"
            }

            do {
                // Create parent directories
                let parentDir = destURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                // Download
                logger.info("Downloading \(urlString) → \(path)")
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse else {
                    return "Error: not an HTTP response"
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    return "Error: HTTP \(httpResponse.statusCode)"
                }

                // Save
                try data.write(to: destURL)
                let sizeKB = data.count / 1024
                logger.info("Downloaded \(sizeKB)KB → \(path)")
                return "Downloaded \(sizeKB)KB → \(path)"
            } catch {
                logger.error("Download failed: \(error.localizedDescription)")
                return "Error: \(error.localizedDescription)"
            }
        }
    }
}

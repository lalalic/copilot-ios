import Foundation
import CopilotSDK
import ffmpegkit
import os.log

private let logger = Logger(subsystem: "com.copilot.mediakit", category: "FFmpeg")

/// Provides `ffmpeg` and `ffprobe` tools that let the agent run arbitrary media processing commands.
/// Files are resolved relative to a configurable base directory (default: Documents/workspace/).
public final class FFmpegToolProvider: Sendable {

    private let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.baseDirectory = docs.appendingPathComponent("workspace")
        }
    }

    // MARK: - Tool Definitions

    public var tools: [ToolDefinition] {
        [ffmpegTool, ffprobeTool]
    }

    private var ffmpegTool: ToolDefinition {
        ToolDefinition(
            name: "ffmpeg",
            description: """
            Run an ffmpeg command for media processing. Supports resize, trim, split, \
            extract audio, remove audio, convert formats, add watermarks, adjust quality, etc. \
            Relative paths are resolved from the workspace directory. \
            Example: ffmpeg -i clip_0.mov -vf scale=1280:720 -c:v libx264 output.mp4
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The ffmpeg command arguments (without the leading 'ffmpeg'). Example: -i input.mp4 -vf scale=1280:720 output.mp4")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            skipPermission: true
        ) { [self] args in
            guard case .object(let dict) = args,
                  case .string(let command) = dict["command"] else {
                return "Error: 'command' string required"
            }
            return await self.executeFFmpeg(command: command)
        }
    }

    private var ffprobeTool: ToolDefinition {
        ToolDefinition(
            name: "ffprobe",
            description: """
            Inspect media file metadata — duration, resolution, codecs, bitrate, audio channels, etc. \
            Relative paths are resolved from the workspace directory. \
            Example: ffprobe -v quiet -print_format json -show_format -show_streams input.mp4
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The ffprobe command arguments (without the leading 'ffprobe'). Example: -v quiet -print_format json -show_format -show_streams input.mp4")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            skipPermission: true
        ) { [self] args in
            guard case .object(let dict) = args,
                  case .string(let command) = dict["command"] else {
                return "Error: 'command' string required"
            }
            return await self.executeFFprobe(command: command)
        }
    }

    // MARK: - Execution

    private func executeFFmpeg(command: String) async -> String {
        let resolved = resolvePathsInCommand(command)
        logger.info("ffmpeg \(resolved)")

        // Ensure output directory exists
        ensureOutputDirectories(in: resolved)

        let session = FFmpegKit.execute(resolved)
        return formatResult(session: session, tool: "ffmpeg")
    }

    private func executeFFprobe(command: String) async -> String {
        let resolved = resolvePathsInCommand(command)
        logger.info("ffprobe \(resolved)")

        let session = FFprobeKit.execute(resolved)
        return formatProbeResult(session: session)
    }

    // MARK: - Path Resolution

    /// Resolve relative file paths in the command to absolute paths under baseDirectory.
    private func resolvePathsInCommand(_ command: String) -> String {
        var tokens = shellTokenize(command)

        for i in 0..<tokens.count {
            let token = tokens[i]
            if token.hasPrefix("-") { continue }
            if looksLikeFilePath(token) {
                tokens[i] = resolve(token)
            }
        }

        return tokens.joined(separator: " ")
    }

    private func looksLikeFilePath(_ token: String) -> Bool {
        let ext = (token as NSString).pathExtension.lowercased()
        let mediaExtensions: Set<String> = [
            "mp4", "mov", "mkv", "avi", "webm", "flv", "m4v",  // video
            "mp3", "aac", "m4a", "wav", "flac", "ogg", "opus", // audio
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", // image
            "srt", "ass", "vtt",                                  // subtitles
            "json", "txt", "md"                                    // data
        ]
        return mediaExtensions.contains(ext)
    }

    private func resolve(_ path: String) -> String {
        path.hasPrefix("/") ? path : baseDirectory.appendingPathComponent(path).path
    }

    private func ensureOutputDirectories(in command: String) {
        let tokens = shellTokenize(command)
        for token in tokens.reversed() {
            if !token.hasPrefix("-") && looksLikeFilePath(token) {
                let url: URL
                if token.hasPrefix("/") {
                    url = URL(fileURLWithPath: token)
                } else {
                    url = baseDirectory.appendingPathComponent(token)
                }
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                break
            }
        }
    }

    /// Simple shell tokenizer that respects single and double quotes.
    private func shellTokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false

        for char in command {
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if char == " " && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Result Formatting

    private func formatResult(session: FFmpegSession?, tool: String) -> String {
        guard let session else { return "Error: \(tool) session failed to start" }

        let rc = session.getReturnCode()
        let output = session.getOutput() ?? ""
        let logs = session.getAllLogsAsString() ?? ""

        if ReturnCode.isSuccess(rc) {
            let duration = session.getDuration()
            var result = "✅ \(tool) completed (\(duration)ms)"
            if !output.isEmpty {
                result += "\n" + String(output.prefix(2000))
            }
            return result
        } else if ReturnCode.isCancel(rc) {
            return "⚠️ \(tool) was cancelled"
        } else {
            var result = "❌ \(tool) failed (rc: \(rc?.getValue() ?? -1))"
            if !logs.isEmpty {
                result += "\n" + String(logs.suffix(2000))
            }
            return result
        }
    }

    private func formatProbeResult(session: FFprobeSession?) -> String {
        guard let session else { return "Error: ffprobe session failed to start" }

        let rc = session.getReturnCode()
        let output = session.getOutput() ?? ""

        if ReturnCode.isSuccess(rc) {
            return output.isEmpty ? "✅ ffprobe completed (no output)" : String(output.prefix(4000))
        } else {
            let logs = session.getAllLogsAsString() ?? ""
            return "❌ ffprobe failed (rc: \(rc?.getValue() ?? -1))\n\(String(logs.suffix(2000)))"
        }
    }
}

import Foundation
import os.log

private let logger = Logger(subsystem: "com.copilot-ios.sdk", category: "FileTools")

/// Provides read_file, write_file, and list_files tools that let an AI agent
/// manage files on the device. All paths are sandboxed under a configurable
/// base directory (default: Documents/workspace/).
///
/// Usage:
/// ```swift
/// let fileTools = FileToolProvider()
/// let tools = fileTools.tools  // [ToolDefinition]
/// ```
public final class FileToolProvider: Sendable {

    /// Base directory for the agent's workspace.
    public let baseDirectory: URL

    /// Create a FileToolProvider with the default workspace directory (Documents/workspace/).
    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.baseDirectory = docs.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Create a FileToolProvider with a custom base directory.
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// All file tools: read_file, write_file, list_files.
    public var tools: [ToolDefinition] {
        [readFileTool, writeFileTool, listFilesTool]
    }

    // MARK: - Path Resolution

    /// Resolve a relative path to an absolute URL within the sandbox.
    /// Returns nil if the resolved path escapes the sandbox.
    private func resolve(_ path: String) -> URL? {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "../", with: "")
        let resolved = baseDirectory.appendingPathComponent(cleaned).standardized
        guard resolved.path.hasPrefix(baseDirectory.path) else { return nil }
        return resolved
    }

    // MARK: - read_file

    private var readFileTool: ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: "Read a file from the on-device workspace. Returns the file content as text.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path within the workspace, e.g. 'production/brief.md'")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            overridesBuiltInTool: true,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: FileToolProvider not available" }
            guard case .object(let dict) = args,
                  case .string(let path) = dict["path"] else {
                return "Error: 'path' (string) required"
            }
            guard let url = self.resolve(path) else {
                return "Error: invalid path '\(path)'"
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return "Error: file not found: \(path)"
            }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                logger.info("read_file: \(path) (\(content.count) chars)")
                return content
            } catch {
                return "Error reading \(path): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - write_file

    private var writeFileTool: ToolDefinition {
        ToolDefinition(
            name: "write_file",
            description: "Write content to a file in the on-device workspace. Creates directories as needed. Overwrites existing files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path within the workspace, e.g. 'production/brief.md'")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The content to write to the file")
                    ])
                ]),
                "required": .array([.string("path"), .string("content")])
            ]),
            overridesBuiltInTool: true,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: FileToolProvider not available" }
            guard case .object(let dict) = args,
                  case .string(let path) = dict["path"],
                  case .string(let content) = dict["content"] else {
                return "Error: 'path' and 'content' required"
            }
            guard let url = self.resolve(path) else {
                return "Error: invalid path '\(path)'"
            }
            do {
                let dir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("write_file: \(path) (\(content.count) chars)")
                return "Written \(content.count) chars to \(path)"
            } catch {
                return "Error writing \(path): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - list_files

    private var listFilesTool: ToolDefinition {
        ToolDefinition(
            name: "list_files",
            description: "List files and directories in the on-device workspace. Returns names with '/' suffix for directories. Omit path to list the workspace root.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative directory path within the workspace. Omit or use '' for root.")
                    ])
                ])
            ]),
            overridesBuiltInTool: true,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: FileToolProvider not available" }
            let path: String
            if case .object(let dict) = args, case .string(let p) = dict["path"] {
                path = p
            } else {
                path = ""
            }
            let url: URL
            if path.isEmpty {
                url = self.baseDirectory
            } else {
                guard let resolved = self.resolve(path) else {
                    return "Error: invalid path '\(path)'"
                }
                url = resolved
            }
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                let names = contents.map { item -> String in
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return isDir ? item.lastPathComponent + "/" : item.lastPathComponent
                }.sorted()
                logger.info("list_files: \(path.isEmpty ? "/" : path) → \(names.count) items")
                if names.isEmpty { return "(empty directory)" }
                return names.joined(separator: "\n")
            } catch {
                return "Error listing \(path.isEmpty ? "/" : path): \(error.localizedDescription)"
            }
        }
    }
}

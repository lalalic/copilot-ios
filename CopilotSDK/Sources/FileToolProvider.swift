import Foundation
import os.log

private let logger = Logger(subsystem: "com.copilot-ios.sdk", category: "FileTools")

/// Provides read_file, write_file, list_files, and create_directory tools that let an AI agent
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

    /// All file tools: read_file, write_file, create_project.
    public var tools: [ToolDefinition] {
        [readFileTool, writeFileTool, createProjectTool]
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

    // MARK: - create_project

    private var createProjectTool: ToolDefinition {
        ToolDefinition(
            name: "create_project",
            description: "Create a new project in the workspace. Steps: 1) Read .templates/projects/{template}/README.md to understand the structure 2) Follow the README to gather required info from the user 3) Call this tool with the gathered info. The client will scaffold the project folder.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Project name (e.g., 'Fitness Tracker')")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("One-line project description")
                    ]),
                    "template": .object([
                        "type": .string("string"),
                        "description": .string("Template name from .templates/projects/ (default: 'general')")
                    ]),
                    "goal": .object([
                        "type": .string("string"),
                        "description": .string("Project goal (1-2 sentences)")
                    ]),
                    "features": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("List of MVP features")
                    ])
                ]),
                "required": .array([.string("name")])
            ]),
            overridesBuiltInTool: false,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: FileToolProvider not available" }
            guard case .object(let dict) = args else {
                return "Error: 'name' (string) required"
            }
            guard case .string(let name) = dict["name"] else {
                if dict["name"] == nil {
                    return "Error: 'name' (string) required"
                }
                return "Error: 'name' (string) required"
            }
            guard !name.isEmpty else {
                return "Error: project name cannot be empty"
            }
            // Validate name: no path traversal, no slashes
            guard !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else {
                return "Error: invalid project name '\(name)'"
            }

            let fm = FileManager.default
            let projectDir = self.baseDirectory.appendingPathComponent(name, isDirectory: true)

            // Check for duplicates
            guard !fm.fileExists(atPath: projectDir.path) else {
                return "Error: project already exists at '\(name)'"
            }

            // Extract optional params
            let description: String? = {
                if case .string(let s) = dict["description"] { return s }
                return nil
            }()
            let templateName: String? = {
                if case .string(let s) = dict["template"] { return s }
                return nil
            }()
            let goal: String? = {
                if case .string(let s) = dict["goal"] { return s }
                return nil
            }()
            let features: [String]? = {
                if case .array(let arr) = dict["features"] {
                    return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                }
                return nil
            }()

            do {
                // Create project directory
                try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

                // Copy template files if template specified
                var templateUsed: String? = nil
                if let tpl = templateName {
                    let templateDir = self.baseDirectory
                        .appendingPathComponent(".templates/projects/\(tpl)", isDirectory: true)
                    if fm.fileExists(atPath: templateDir.path) {
                        // Copy all template contents except README.md (we'll generate that)
                        let contents = try fm.contentsOfDirectory(
                            at: templateDir, includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        )
                        for item in contents {
                            let itemName = item.lastPathComponent
                            if itemName.lowercased() == "readme.md" { continue }
                            let dest = projectDir.appendingPathComponent(itemName)
                            try fm.copyItem(at: item, to: dest)
                        }
                        templateUsed = tpl
                    }
                }

                // Create default directories
                for dir in ["docs", "progress"] {
                    let dirURL = projectDir.appendingPathComponent(dir, isDirectory: true)
                    if !fm.fileExists(atPath: dirURL.path) {
                        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    }
                }

                // Generate README.md
                var readme = "---\nname: \(name)\n"
                if let desc = description { readme += "description: \(desc)\n" }
                if let tpl = templateUsed { readme += "template: \(tpl)\n" }
                readme += "---\n\n# \(name)\n"
                if let desc = description { readme += "\n\(desc)\n" }
                if let g = goal {
                    readme += "\n# goal\n\(g)\n"
                }
                if let feats = features, !feats.isEmpty {
                    readme += "\n# features\n"
                    for f in feats { readme += "- [ ] \(f)\n" }
                }

                try readme.write(
                    to: projectDir.appendingPathComponent("README.md"),
                    atomically: true, encoding: .utf8
                )

                // Generate package.json
                var pkg: [String: Any] = ["name": name, "version": "0.1.0"]
                if let desc = description { pkg["description"] = desc }
                if let tpl = templateUsed { pkg["projectType"] = tpl }
                let pkgData = try JSONSerialization.data(withJSONObject: pkg, options: [.prettyPrinted, .sortedKeys])
                try pkgData.write(to: projectDir.appendingPathComponent("package.json"))

                var msg = "Created project '\(name)'"
                if let tpl = templateUsed { msg += " from template '\(tpl)'" }
                msg += " at \(name)/"
                logger.info("create_project: \(msg)")
                return msg
            } catch {
                // Clean up on failure
                try? fm.removeItem(at: projectDir)
                return "Error creating project: \(error.localizedDescription)"
            }
        }
    }
}

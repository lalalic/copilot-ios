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

    /// All file tools: read_file, write_file, list_files, create_directory, create_project.
    public var tools: [ToolDefinition] {
        [readFileTool, writeFileTool, listFilesTool, createDirectoryTool, createProjectTool]
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

    // MARK: - create_new_project

    private var createDirectoryTool: ToolDefinition {
        ToolDefinition(
            name: "create_directory",
            description: "Create a directory inside the on-device workspace. Supports nested paths and creates missing parents.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative directory path within the workspace, e.g. 'project/docs' or 'assets/images'.")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            overridesBuiltInTool: true,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: FileToolProvider not available" }
            guard case .object(let dict) = args,
                  case .string(let rawPath) = dict["path"] else {
                return "Error: 'path' (string) required"
            }

            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                return "Error: path cannot be empty"
            }

            guard let url = self.resolve(path) else {
                return "Error: invalid path '\(rawPath)'"
            }

            do {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        return "Directory already exists: \(path)"
                    }
                    return "Error: path exists and is a file: \(path)"
                }

                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                logger.info("create_directory: \(path)")
                return "Created directory: \(path)"
            } catch {
                return "Error creating directory \(path): \(error.localizedDescription)"
            }
        }
    }

    private var createProjectTool: ToolDefinition {
        ToolDefinition(
            name: "create_project",
            description: "Create a new project in the workspace. Steps: 1) Read .templates/projects/{template}/README.md to understand the structure 2) Follow the README to gather required info from the user 3) Call this tool with the gathered info. The client will scaffold the project folder from the template.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Project folder name, e.g. 'FitnessTracker' or 'RecipeApp'.")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("One-line project description.")
                    ]),
                    "template": .object([
                        "type": .string("string"),
                        "description": .string("Template name from .templates/projects/ (default: 'general').")
                    ]),
                    "goal": .object([
                        "type": .string("string"),
                        "description": .string("Project goal (1-2 sentences).")
                    ]),
                    "features": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("List of MVP features.")
                    ])
                ]),
                "required": .array([.string("name")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: FileToolProvider not available" }
            guard case .object(let dict) = args,
                  case .string(let rawName) = dict["name"] else {
                return "Error: 'name' (string) required"
            }

            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return "Error: project name cannot be empty"
            }
            guard !name.contains("/"), !name.contains("..") else {
                return "Error: invalid project name '\(rawName)'"
            }

            let description = dict["description"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
            let templateName = dict["template"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? "general"
            let goal = dict["goal"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }
            let features: [String] = {
                guard case .array(let arr) = dict["features"] else { return [] }
                return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            }()

            let projectURL = self.baseDirectory.appendingPathComponent(name, isDirectory: true)
            guard projectURL.path.hasPrefix(self.baseDirectory.path) else {
                return "Error: invalid project path"
            }

            if FileManager.default.fileExists(atPath: projectURL.path) {
                return "Error: project already exists: \(name)"
            }

            do {
                try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

                let templateURL = self.baseDirectory
                    .appendingPathComponent(".templates", isDirectory: true)
                    .appendingPathComponent("projects", isDirectory: true)
                    .appendingPathComponent(templateName, isDirectory: true)

                if FileManager.default.fileExists(atPath: templateURL.path) {
                    try self.copyTemplateProject(from: templateURL, to: projectURL)
                } else {
                    try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("progress", isDirectory: true), withIntermediateDirectories: true)
                }

                // Build README.md from provided info
                let readme = self.buildProjectReadme(
                    name: name,
                    description: description,
                    goal: goal,
                    features: features
                )
                try readme.write(to: projectURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

                logger.info("create_project: \(name) (template: \(templateName))")
                return "Created project '\(name)' from template '\(templateName)'"
            } catch {
                return "Error creating project \(name): \(error.localizedDescription)"
            }
        }
    }

    private func buildProjectReadme(name: String, description: String?, goal: String?, features: [String]) -> String {
        var lines: [String] = []

        // Frontmatter
        lines.append("---")
        lines.append("name: \(name)")
        if let description, !description.isEmpty {
            lines.append("description: \(description)")
        }
        lines.append("---")
        lines.append("")

        // Goal
        lines.append("# goal")
        lines.append(goal ?? "define project goal with 1 or 2 sentences")
        lines.append("")

        // Features
        lines.append("# feature")
        if features.isEmpty {
            lines.append("- [ ] title")
        } else {
            for feature in features {
                lines.append("- [ ] \(feature)")
            }
        }
        lines.append("")

        // Strategy
        lines.append("# strategy")
        lines.append("define implementation strategy")
        lines.append("")

        // Implementation phases
        lines.append("# implementation phrases")
        lines.append("define high level phrases to implement goal")
        lines.append("- [ ] title")
        lines.append("")

        // References
        lines.append("# references")
        lines.append("- **docs/**: project docs, detail requirements, design, knowledge, and etc")
        lines.append("- **progress/**: project plan, todo, report, and etc")

        return lines.joined(separator: "\n")
    }

    private func copyTemplateProject(from templateURL: URL, to projectURL: URL) throws {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]

        let enumerator = manager.enumerator(
            at: templateURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            let relativePath = item.path.replacingOccurrences(of: templateURL.path + "/", with: "")
            if relativePath.isEmpty { continue }

            let destination = projectURL.appendingPathComponent(relativePath)
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(at: item, to: destination)
            }
        }
    }
}

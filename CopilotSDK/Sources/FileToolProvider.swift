import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Vision)
import Vision
#endif
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

    /// Returns true when the current model supports image inputs (vision).
    /// Set by the coordinator after construction.
    public let modelSupportsImages: @Sendable () -> Bool

    /// Optional closure to describe an image using the LLM (for direct callers like StepEditorView).
    /// Receives (imageData, mimeType, prompt) and returns the LLM's text description.
    /// Set by the coordinator to route through the orchestrator session.
    public nonisolated(unsafe) var describeImageWithLLM: (@Sendable (_ imageData: Data, _ mimeType: String, _ prompt: String) async -> String?)?

    /// Create a FileToolProvider with the default workspace directory (Documents/workspace/).
    public init(
        modelSupportsImages: @escaping @Sendable () -> Bool = { true }
    ) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.baseDirectory = docs.appendingPathComponent("workspace", isDirectory: true)
        self.modelSupportsImages = modelSupportsImages
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Create a FileToolProvider with a custom base directory.
    public init(
        baseDirectory: URL,
        modelSupportsImages: @escaping @Sendable () -> Bool = { true }
    ) {
        self.baseDirectory = baseDirectory
        self.modelSupportsImages = modelSupportsImages
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// All file tools: read_file, write_file, patch_file, create_project, describe_media.
    public var tools: [ToolDefinition] {
        [readFileTool, writeFileTool, patchFileTool, createProjectTool, describeMediaTool]
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

    // MARK: - patch_file

    private var patchFileTool: ToolDefinition {
        ToolDefinition(
            name: "patch_file",
            description: "Apply a targeted edit to an existing file. Replaces the first occurrence of `old_string` with `new_string`. More efficient than rewriting the whole file with write_file. Use for small edits to large files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path within the workspace")
                    ]),
                    "old_string": .object([
                        "type": .string("string"),
                        "description": .string("Exact text to find and replace (must match exactly)")
                    ]),
                    "new_string": .object([
                        "type": .string("string"),
                        "description": .string("Replacement text")
                    ])
                ]),
                "required": .array([.string("path"), .string("old_string"), .string("new_string")])
            ]),
            overridesBuiltInTool: true,
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: FileToolProvider not available" }
            guard case .object(let dict) = args,
                  case .string(let path) = dict["path"],
                  case .string(let oldStr) = dict["old_string"],
                  case .string(let newStr) = dict["new_string"] else {
                return "Error: 'path', 'old_string', and 'new_string' required"
            }
            guard let url = self.resolve(path) else {
                return "Error: invalid path '\(path)'"
            }
            do {
                var content = try String(contentsOf: url, encoding: .utf8)
                guard let range = content.range(of: oldStr) else {
                    return "Error: old_string not found in \(path)"
                }
                content.replaceSubrange(range, with: newStr)
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("patch_file: \(path) replaced \(oldStr.count) → \(newStr.count) chars")
                return "Patched \(path): replaced \(oldStr.count) chars with \(newStr.count) chars"
            } catch {
                return "Error patching \(path): \(error.localizedDescription)"
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

    // MARK: - describe_media

    private var describeMediaTool: ToolDefinition {
        ToolDefinition(
            name: "describe_media",
            description: "Describe an image file. When the model supports vision, returns base64 image data. Otherwise, uses on-device analysis (scene classification, OCR, saliency) to return a text description. Only works with image files (jpg, png, gif, webp, heic, bmp, tiff, svg).",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Workspace-relative path to an image file"),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ]),
            skipPermission: true,
            handler: { [self] args in
                guard case .object(let dict) = args,
                      case .string(let path) = dict["path"] else {
                    return "Error: missing 'path' parameter"
                }

                let ext = (path as NSString).pathExtension.lowercased()
                let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg"]
                guard imageExtensions.contains(ext) else {
                    return "Error: '\(path)' is not an image file. Supported: \(imageExtensions.sorted().joined(separator: ", "))."
                }

                guard let fileURL = resolve(path) else {
                    return "Error: path escapes sandbox"
                }
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return "Error: image not found at '\(path)'"
                }
                guard let data = try? Data(contentsOf: fileURL) else {
                    return "Error: failed to read image at '\(path)'"
                }

                if modelSupportsImages() {
                    return Self.imageAsBase64(data: data, path: path, ext: ext)
                } else {
                    return await Self.analyzeOnDevice(data: data, path: path)
                }
            }
        )
    }

    /// Return resized base64 image data for vision models.
    private static func imageAsBase64(data: Data, path: String, ext: String) -> String {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            let maxDim: CGFloat = 768
            let size = image.size
            let maxSide = max(size.width, size.height)
            let targetSize: CGSize
            if maxSide > maxDim {
                let scale = maxDim / maxSide
                targetSize = CGSize(width: size.width * scale, height: size.height * scale)
            } else {
                targetSize = size
            }
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let jpegData = renderer.jpegData(withCompressionQuality: 0.7) { ctx in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            return "[image:\(path)] data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        }
        #endif
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "svg": mime = "image/svg+xml"
        default: mime = "image/jpeg"
        }
        return "[image:\(path)] data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Describe a media file directly (without going through the LLM agent loop).
    /// For vision models: sends the image to the LLM via describeImageWithLLM and returns text.
    /// For non-vision models: uses on-device Vision framework analysis.
    /// Falls back to on-device analysis if describeImageWithLLM is not set.
    public func describeMedia(data: Data, filename: String) async -> String {
        if modelSupportsImages(), let describe = describeImageWithLLM {
            // Send to LLM for vision-based description
            if let description = await describe(data, "image/jpeg", "Describe this image concisely: what's in it, the scene, mood, and any notable details.") {
                return description
            }
        }
        // Fallback: on-device analysis
        let relativePath = filename
        return await Self.analyzeOnDevice(data: data, path: relativePath)
    }

    /// On-device Vision framework analysis for non-vision models.
    private static func analyzeOnDevice(data: Data, path: String) async -> String {
        #if canImport(UIKit) && canImport(Vision)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            return "[image:\(path)] Error: could not decode image for on-device analysis"
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let classifyRequest = VNClassifyImageRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        try? handler.perform([classifyRequest, textRequest, saliencyRequest])

        let sceneLabels = (classifyRequest.results ?? [])
            .filter { $0.confidence > 0.1 }
            .prefix(8)
            .map { "\($0.identifier) (\(String(format: "%.0f%%", $0.confidence * 100)))" }

        let texts = (textRequest.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }

        var focalPointCount = 0
        if let saliencyMap = saliencyRequest.results?.first {
            focalPointCount = saliencyMap.salientObjects?.count ?? 0
        }

        var parts: [String] = []
        parts.append("[image:\(path)]")
        parts.append("Size: \(Int(image.size.width))x\(Int(image.size.height))")
        if !sceneLabels.isEmpty {
            parts.append("Scene: \(sceneLabels.joined(separator: ", "))")
        }
        if !texts.isEmpty {
            parts.append("Text found: \(texts.joined(separator: " | "))")
        }
        if focalPointCount > 0 {
            parts.append("Focal points: \(focalPointCount)")
        }
        return parts.joined(separator: "\n")
        #else
        return "[image:\(path)] On-device analysis unavailable on this platform"
        #endif
    }
}

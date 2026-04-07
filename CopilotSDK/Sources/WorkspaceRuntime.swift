import Foundation
import ZIPFoundation

// MARK: - Skill Discovery

/// A discovered skill from the workspace's `.github/skills/` directory.
public struct SkillDescriptor: Sendable, Equatable {
    /// Skill name from frontmatter.
    public let name: String
    /// Skill description from frontmatter.
    public let description: String
    /// Workspace-relative file path (e.g. ".github/skills/photo-editor/SKILL.md").
    public let filePath: String

    public init(name: String, description: String, filePath: String) {
        self.name = name
        self.description = description
        self.filePath = filePath
    }
}

/// Scans a workspace for SKILL.md files and parses their frontmatter.
public final class SkillDiscovery: Sendable {

    public init() {}

    /// Discover skills in `workspaceURL/.github/skills/*/SKILL.md`.
    /// Returns descriptors for every skill with valid `name` and `description` frontmatter.
    /// Never throws — missing directories or invalid files are silently skipped.
    public func discover(in workspaceURL: URL) -> [SkillDescriptor] {
        let skillsDir = workspaceURL
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var skills: [SkillDescriptor] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path),
                  let raw = try? String(contentsOf: skillFile, encoding: .utf8),
                  let descriptor = parseSkillFrontmatter(raw, dirName: entry.lastPathComponent) else {
                continue
            }
            skills.append(descriptor)
        }
        return skills.sorted { $0.name < $1.name }
    }

    /// Parse YAML frontmatter from a SKILL.md for `name` and `description`.
    private func parseSkillFrontmatter(_ raw: String, dirName: String) -> SkillDescriptor? {
        guard raw.hasPrefix("---\n"),
              let closing = raw.range(of: "\n---\n") else { return nil }

        let fmStart = raw.index(raw.startIndex, offsetBy: 4)
        let frontmatter = String(raw[fmStart..<closing.lowerBound])

        var name: String?
        var description: String?
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip surrounding quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if key == "name" { name = value }
            else if key == "description" { description = value }
        }

        guard let name, !name.isEmpty, let description, !description.isEmpty else { return nil }
        let relativePath = ".github/skills/\(dirName)/SKILL.md"
        return SkillDescriptor(name: name, description: description, filePath: relativePath)
    }

    /// Build the `<instructions><skills>…</skills></instructions>` section for the system prompt.
    /// Returns nil if skills is empty.
    public static func buildPromptSection(from skills: [SkillDescriptor]) -> String? {
        guard !skills.isEmpty else { return nil }
        var section = "<instructions>\nHere is a list of skills on this phone that contain domain specific knowledge on a variety of topics.\nEach skill comes with a description of the topic and a file path that contains the detailed instructions.\nWhen a user asks you to perform a task that falls within the domain of a skill, use the 'read_file' tool to acquire the full instructions from the file path.\n<skills>\n"
        for skill in skills {
            section += "<skill>\n<name>\(skill.name)</name>\n<description>\(skill.description)</description>\n<file>\(skill.filePath)</file>\n</skill>\n"
        }
        section += "</skills>\n</instructions>"
        return section
    }
}

// MARK: - Agent Runtime Profile

public struct AgentRuntimeProfile: Sendable {
    public let defaultModel: String?
    public let description: String?
    public let tools: [String]?
    public let preambleBody: String?
    public let sections: [String: SystemMessageSectionAction]
    /// Discovered on-device skills from `.github/skills/`.
    public let skills: [SkillDescriptor]

    public init(
        defaultModel: String?,
        description: String?,
        tools: [String]?,
        preambleBody: String?,
        sections: [String: SystemMessageSectionAction],
        skills: [SkillDescriptor] = []
    ) {
        self.defaultModel = defaultModel
        self.description = description
        self.tools = tools
        self.preambleBody = preambleBody
        self.sections = sections
        self.skills = skills
    }
}

public final class WorkspaceBootstrapper: Sendable {
    public let workspaceFolderName: String
    public let bundledZipName: String

    public init(workspaceFolderName: String = "workspace", bundledZipName: String = "workspace") {
        self.workspaceFolderName = workspaceFolderName
        self.bundledZipName = bundledZipName
    }

    public func ensureWorkspaceReady(bundle: Bundle = .main) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let workspaceURL = appSupport.appendingPathComponent(workspaceFolderName, isDirectory: true)
        let workspaceExists = FileManager.default.fileExists(atPath: workspaceURL.path)

        if !workspaceExists {
            if let zipURL = bundle.url(forResource: bundledZipName, withExtension: "zip") {
                try FileManager.default.unzipItem(at: zipURL, to: appSupport)
            } else if let packageZipURL = Bundle.module.url(forResource: bundledZipName, withExtension: "zip") {
                try FileManager.default.unzipItem(at: packageZipURL, to: appSupport)
            }
            if !FileManager.default.fileExists(atPath: workspaceURL.path) {
                try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            }
        }

        // Always sync .templates/ from bundle (they may be updated between app versions)
        syncTemplatesFromBundle(bundle: bundle, workspaceURL: workspaceURL)

        // Always sync .github/agents/ from bundle (new agents may be added between versions)
        syncAgentsFromBundle(bundle: bundle, workspaceURL: workspaceURL)

        return workspaceURL
    }

    /// Re-extract .templates/ directory from bundled zip on every launch.
    private func syncTemplatesFromBundle(bundle: Bundle, workspaceURL: URL) {
        let zipURL = bundle.url(forResource: bundledZipName, withExtension: "zip")
            ?? Bundle.module.url(forResource: bundledZipName, withExtension: "zip")
        guard let zipURL else { return }

        let manager = FileManager.default
        let tempDir = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: tempDir) }

        do {
            try manager.unzipItem(at: zipURL, to: tempDir)
            let extractedTemplates = tempDir
                .appendingPathComponent(workspaceFolderName)
                .appendingPathComponent(".templates")
            guard manager.fileExists(atPath: extractedTemplates.path) else { return }

            let destTemplates = workspaceURL.appendingPathComponent(".templates")
            if manager.fileExists(atPath: destTemplates.path) {
                try manager.removeItem(at: destTemplates)
            }
            try manager.copyItem(at: extractedTemplates, to: destTemplates)
        } catch {
            // Non-fatal: templates sync failure doesn't prevent app launch
        }
    }

    /// Sync .github/agents/ from bundled zip — adds new agents without overwriting user-modified ones.
    private func syncAgentsFromBundle(bundle: Bundle, workspaceURL: URL) {
        let mainURL = bundle.url(forResource: bundledZipName, withExtension: "zip")
        let moduleURL = Bundle.module.url(forResource: bundledZipName, withExtension: "zip")
        let zipURL = mainURL ?? moduleURL
        NSLog("[Workspace] syncAgents: mainURL=%@ moduleURL=%@ bundledZipName=%@",
              mainURL?.path ?? "nil", moduleURL?.path ?? "nil", bundledZipName)
        guard let zipURL else {
            NSLog("[Workspace] syncAgents: no zip found (bundledZipName=%@)", bundledZipName)
            return
        }

        let manager = FileManager.default
        let tempDir = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: tempDir) }

        do {
            try manager.unzipItem(at: zipURL, to: tempDir)
            let extractedAgents = tempDir
                .appendingPathComponent(workspaceFolderName)
                .appendingPathComponent(".github")
                .appendingPathComponent("agents")
            guard manager.fileExists(atPath: extractedAgents.path) else {
                NSLog("[Workspace] syncAgents: no agents dir in zip at %@", extractedAgents.path)
                return
            }

            let destAgents = workspaceURL
                .appendingPathComponent(".github")
                .appendingPathComponent("agents")
            try manager.createDirectory(at: destAgents, withIntermediateDirectories: true)

            // Only add new files, don't overwrite existing
            let files = try manager.contentsOfDirectory(at: extractedAgents, includingPropertiesForKeys: nil)
            var added = 0
            for file in files {
                let dest = destAgents.appendingPathComponent(file.lastPathComponent)
                if !manager.fileExists(atPath: dest.path) {
                    try manager.copyItem(at: file, to: dest)
                    added += 1
                }
            }
            NSLog("[Workspace] syncAgents: %d agents in zip, %d newly added to %@", files.count, added, destAgents.path)
        } catch {
            NSLog("[Workspace] syncAgents error: %@", error.localizedDescription)
        }
    }
}

public final class AgentProfileLoader: Sendable {
    private let knownSections: Set<String> = [
        "identity", "tone", "tool_efficiency", "environment_context",
        "code_change_rules", "guidelines", "safety", "tool_instructions",
        "custom_instructions", "last_instructions",
    ]

    private let headerMap: [String: String] = [
        "identity": "identity",
        "tone": "tone",
        "capabilities": "identity",
        "core_behavior": "guidelines",
        "behavior": "guidelines",
        "guidelines": "guidelines",
        "safety": "safety",
        "tools": "tool_instructions",
        "tool_instructions": "tool_instructions",
        "custom_instructions": "custom_instructions",
        "last_instructions": "last_instructions",
        "environment": "environment_context",
        "environment_context": "environment_context",
    ]

    public init() {}

    public func load(from workspaceURL: URL) throws -> AgentRuntimeProfile {
        let skills = SkillDiscovery().discover(in: workspaceURL)

        let agentFileURL = workspaceURL
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("main.agent.md")

        guard FileManager.default.fileExists(atPath: agentFileURL.path) else {
            return AgentRuntimeProfile(defaultModel: nil, description: nil, tools: nil, preambleBody: nil, sections: [:], skills: skills)
        }

        let raw = try String(contentsOf: agentFileURL, encoding: .utf8)

        guard let fmRange = frontmatterRange(in: raw) else {
            return AgentRuntimeProfile(defaultModel: nil, description: nil, tools: nil, preambleBody: raw.trimmingCharacters(in: .whitespacesAndNewlines), sections: [:], skills: skills)
        }

        let frontmatter = String(raw[fmRange.frontmatter])
        let bodyRaw = String(raw[fmRange.body]).trimmingCharacters(in: .whitespacesAndNewlines)

        let parsedFrontmatter = parseFrontmatter(frontmatter)
        let parsedBody = parseBodySections(bodyRaw)

        return AgentRuntimeProfile(
            defaultModel: parsedFrontmatter.model,
            description: parsedFrontmatter.description,
            tools: parsedFrontmatter.tools,
            preambleBody: parsedBody.preamble,
            sections: parsedBody.sections,
            skills: skills
        )
    }

    private func frontmatterRange(in raw: String) -> (frontmatter: Range<String.Index>, body: Range<String.Index>)? {
        guard raw.hasPrefix("---\n") else { return nil }
        guard let closing = raw.range(of: "\n---\n") else { return nil }

        let fmStart = raw.index(raw.startIndex, offsetBy: 4)
        let fmEnd = closing.lowerBound
        let bodyStart = closing.upperBound
        let bodyEnd = raw.endIndex

        return (fmStart..<fmEnd, bodyStart..<bodyEnd)
    }

    private func parseFrontmatter(_ frontmatter: String) -> (model: String?, description: String?, tools: [String]?) {
        var model: String?
        var description: String?
        var tools: [String]?

        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard let split = text.firstIndex(of: ":") else { continue }
            let key = text[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = text[text.index(after: split)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "model" {
                model = value
            } else if key == "description" {
                description = value
            } else if key == "tools", value.hasPrefix("["), value.hasSuffix("]") {
                let content = String(value.dropFirst().dropLast())
                tools = content
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }

        return (model, description, tools)
    }

    private func parseBodySections(_ body: String) -> (preamble: String?, sections: [String: SystemMessageSectionAction]) {
        var preamble: [String] = []
        var sections: [String: SystemMessageSectionAction] = [:]
        var currentSection: String?
        var currentContent: [String] = []

        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let title = h1Title(from: line) {
                if let currentSection {
                    let content = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    sections[currentSection] = .replace(content: content)
                } else if !currentContent.isEmpty {
                    preamble.append(contentsOf: currentContent)
                }

                let normalized = normalizeHeader(title)
                let mapped = headerMap[normalized] ?? (knownSections.contains(normalized) ? normalized : nil)
                currentSection = mapped
                currentContent = []

                if currentSection == nil {
                    preamble.append(line)
                }
            } else {
                currentContent.append(line)
            }
        }

        if let currentSection {
            let content = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            sections[currentSection] = .replace(content: content)
        } else if !currentContent.isEmpty {
            preamble.append(contentsOf: currentContent)
        }

        let preambleText = preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (preambleText.isEmpty ? nil : preambleText, sections)
    }

    private func h1Title(from line: String) -> String? {
        guard line.hasPrefix("# ") else { return nil }
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeHeader(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}
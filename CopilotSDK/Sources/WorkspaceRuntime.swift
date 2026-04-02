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

        if FileManager.default.fileExists(atPath: workspaceURL.path) {
            return workspaceURL
        }

        if let zipURL = bundle.url(forResource: bundledZipName, withExtension: "zip") {
            try FileManager.default.unzipItem(at: zipURL, to: appSupport)
        } else if let packageZipURL = Bundle.module.url(forResource: bundledZipName, withExtension: "zip") {
            try FileManager.default.unzipItem(at: packageZipURL, to: appSupport)
        }

        if !FileManager.default.fileExists(atPath: workspaceURL.path) {
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        }

        return workspaceURL
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
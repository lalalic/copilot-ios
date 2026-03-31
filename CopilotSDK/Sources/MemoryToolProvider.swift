import Foundation
import os.log

private let memoryLogger = Logger(subsystem: "com.copilot-ios.sdk", category: "MemoryTools")

public final class MemoryToolProvider: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        ensureNeoDirectories()
    }

    public var tools: [ToolDefinition] {
        [memoryReadTool, memoryAppendTool, memoryWriteSectionTool, memoryLogSessionTool, memoryListTool]
    }

    private var neoDirectory: URL {
        baseDirectory.appendingPathComponent(".neo", isDirectory: true)
    }

    private var defaultMemoryFile: URL {
        neoDirectory.appendingPathComponent("memory.md")
    }

    private func ensureNeoDirectories() {
        try? FileManager.default.createDirectory(at: neoDirectory, withIntermediateDirectories: true)
        let reports = neoDirectory.appendingPathComponent("reports", isDirectory: true)
        let sessions = reports.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    private func resolveNeoPath(_ path: String?) -> URL? {
        let relative = (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? path!.trimmingCharacters(in: .whitespacesAndNewlines)
            : ".neo/memory.md"
        let sanitized = relative.replacingOccurrences(of: "../", with: "")
        let resolved = baseDirectory.appendingPathComponent(sanitized).standardized
        let neoRoot = neoDirectory.standardized
        guard resolved.path.hasPrefix(neoRoot.path) else { return nil }
        return resolved
    }

    private func readString(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func writeString(_ content: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func extractSection(_ section: String, from content: String) -> String? {
        let target = section.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = content.components(separatedBy: "\n")
        var start: Int?
        var end: Int?

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                let title = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "## ", with: "")
                    .replacingOccurrences(of: "# ", with: "")
                if start == nil, title.caseInsensitiveCompare(target) == .orderedSame {
                    start = index
                    continue
                }
                if start != nil {
                    end = index
                    break
                }
            }
        }

        guard let start else { return nil }
        let stop = end ?? lines.count
        return lines[start..<stop].joined(separator: "\n")
    }

    private func replaceOrAppendSection(_ section: String, with body: String, in content: String) -> String {
        let sectionLine = "## \(section.trimmingCharacters(in: .whitespacesAndNewlines))"
        let lines = content.components(separatedBy: "\n")

        var start: Int?
        var end: Int?

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("## ") {
                if start == nil, line.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(sectionLine) == .orderedSame {
                    start = index
                    continue
                }
                if start != nil {
                    end = index
                    break
                }
            }
        }

        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = ([sectionLine] + (normalizedBody.isEmpty ? [] : [normalizedBody])).joined(separator: "\n")

        if let start {
            let stop = end ?? lines.count
            var resultLines = Array(lines[0..<start])
            resultLines.append(contentsOf: replacement.components(separatedBy: "\n"))
            if stop < lines.count {
                resultLines.append(contentsOf: lines[stop...])
            }
            return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        let prefix = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            return replacement + "\n"
        }
        return prefix + "\n\n" + replacement + "\n"
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private func sessionFileName(topic: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let time = formatter.string(from: Date())
        let slug = topic
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeSlug = slug.isEmpty ? "session" : slug
        return "\(time)-\(safeSlug).md"
    }

    private var memoryReadTool: ToolDefinition {
        ToolDefinition(
            name: "memory_read",
            description: "Read memory markdown under .neo. Defaults to .neo/memory.md. Optionally read only a named section.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Path under .neo/, e.g. '.neo/memory.md'")
                    ]),
                    "section": .object([
                        "type": .string("string"),
                        "description": .string("Optional section title to extract (matches #/## headings)")
                    ])
                ])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }
            guard case .object(let dict) = args else { return "Error: object args required" }
            let path: String?
            if case .string(let p) = dict["path"] { path = p } else { path = nil }
            let section: String?
            if case .string(let s) = dict["section"] { section = s } else { section = nil }

            guard let url = self.resolveNeoPath(path) else { return "Error: invalid .neo path" }
            let content = try self.readString(at: url)
            if let section, !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return self.extractSection(section, from: content) ?? ""
            }
            return content
        }
    }

    private var memoryAppendTool: ToolDefinition {
        ToolDefinition(
            name: "memory_append",
            description: "Append timestamped memory content under .neo/memory.md (or another .neo file). Optional section writes under a section heading.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Content to append")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional .neo path; default .neo/memory.md")
                    ]),
                    "section": .object([
                        "type": .string("string"),
                        "description": .string("Optional section heading to append beneath")
                    ])
                ]),
                "required": .array([.string("content")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }
            guard case .object(let dict) = args,
                  case .string(let content) = dict["content"] else {
                return "Error: 'content' required"
            }
            let path: String?
            if case .string(let p) = dict["path"] { path = p } else { path = nil }
            let section: String?
            if case .string(let s) = dict["section"] { section = s } else { section = nil }

            guard let url = self.resolveNeoPath(path) else { return "Error: invalid .neo path" }
            var existing = try self.readString(at: url).trimmingCharacters(in: .whitespacesAndNewlines)

            let entry = "- [\(self.timestamp())] \(content.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let section, !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let merged = self.replaceOrAppendSection(section, with: [
                    self.extractSection(section, from: existing)?.components(separatedBy: "\n").dropFirst().joined(separator: "\n") ?? "",
                    entry
                ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n"), in: existing)
                try self.writeString(merged, to: url)
            } else {
                if existing.isEmpty {
                    existing = "# memory\n\n\(entry)"
                } else {
                    existing += "\n\n\(entry)"
                }
                try self.writeString(existing + "\n", to: url)
            }

            memoryLogger.info("memory_append: \(url.lastPathComponent, privacy: .public)")
            return "Appended memory to \(url.lastPathComponent)"
        }
    }

    private var memoryWriteSectionTool: ToolDefinition {
        ToolDefinition(
            name: "memory_write_section",
            description: "Replace or create a ## section in a memory markdown file under .neo.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "section": .object([
                        "type": .string("string"),
                        "description": .string("Section title (without #)")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Section body text")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional .neo path; default .neo/memory.md")
                    ])
                ]),
                "required": .array([.string("section"), .string("content")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }
            guard case .object(let dict) = args,
                  case .string(let section) = dict["section"],
                  case .string(let content) = dict["content"] else {
                return "Error: 'section' and 'content' required"
            }
            let path: String?
            if case .string(let p) = dict["path"] { path = p } else { path = nil }
            guard let url = self.resolveNeoPath(path) else { return "Error: invalid .neo path" }

            let existing = try self.readString(at: url)
            let merged = self.replaceOrAppendSection(section, with: content, in: existing)
            try self.writeString(merged, to: url)
            memoryLogger.info("memory_write_section: \(section, privacy: .public)")
            return "Updated section '\(section)' in \(url.lastPathComponent)"
        }
    }

    private var memoryLogSessionTool: ToolDefinition {
        ToolDefinition(
            name: "memory_log_session",
            description: "Create a session memory note under .neo/reports/sessions with topic and summary.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "topic": .object([
                        "type": .string("string"),
                        "description": .string("Session topic")
                    ]),
                    "summary": .object([
                        "type": .string("string"),
                        "description": .string("Session summary content")
                    ])
                ]),
                "required": .array([.string("topic"), .string("summary")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }
            guard case .object(let dict) = args,
                  case .string(let topic) = dict["topic"],
                  case .string(let summary) = dict["summary"] else {
                return "Error: 'topic' and 'summary' required"
            }

            let fileName = self.sessionFileName(topic: topic)
            let sessionURL = self.neoDirectory
                .appendingPathComponent("reports", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(fileName)

            let body = """
            # session
            - topic: \(topic)
            - timestamp: \(self.timestamp())

            ## summary
            \(summary.trimmingCharacters(in: .whitespacesAndNewlines))
            """
            try self.writeString(body + "\n", to: sessionURL)
            memoryLogger.info("memory_log_session: \(fileName, privacy: .public)")
            return "Logged session to .neo/reports/sessions/\(fileName)"
        }
    }

    private var memoryListTool: ToolDefinition {
        ToolDefinition(
            name: "memory_list",
            description: "List files/directories under .neo memory workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional path under .neo/, e.g. '.neo/reports/sessions'")
                    ])
                ])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }
            let path: String?
            if case .object(let dict) = args, case .string(let p) = dict["path"] {
                path = p
            } else {
                path = ".neo"
            }

            guard let url = self.resolveNeoPath(path) else { return "Error: invalid .neo path" }
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let names = contents.map { item -> String in
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDir ? item.lastPathComponent + "/" : item.lastPathComponent
            }.sorted()
            return names.joined(separator: "\n")
        }
    }
}

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
        [memoryReadTool, memoryAppendTool, memoryWriteSectionTool, memoryLogSessionTool, memoryListTool, memorySearchTool, memoryDeleteTool, memoryGetYesterdayTool]
    }

    private var neoDirectory: URL {
        baseDirectory.appendingPathComponent(".neo", isDirectory: true)
    }

    private var defaultMemoryFile: URL {
        neoDirectory.appendingPathComponent("memory.md")
    }

    private func ensureNeoDirectories() {
        let fm = FileManager.default
        let dirs = [
            neoDirectory,
            neoDirectory.appendingPathComponent("memory/topics", isDirectory: true),
            neoDirectory.appendingPathComponent("memory/projects", isDirectory: true),
            neoDirectory.appendingPathComponent("knowledge", isDirectory: true),
            neoDirectory.appendingPathComponent("reports/sessions", isDirectory: true),
            neoDirectory.appendingPathComponent("reports/subagents", isDirectory: true),
            neoDirectory.appendingPathComponent("reports/daily", isDirectory: true),
            neoDirectory.appendingPathComponent("reports/weekly", isDirectory: true),
            neoDirectory.appendingPathComponent("reports/monthly", isDirectory: true),
            neoDirectory.appendingPathComponent("reports/yearly", isDirectory: true),
        ]
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Seed user profile template
        let profileFile = neoDirectory.appendingPathComponent("memory/user-profile.md")
        if !fm.fileExists(atPath: profileFile.path) {
            let template = """
            # User Profile

            ## Identity
            - Name:
            - Timezone:
            - Language:

            ## Preferences
            - Communication style:
            - Verbosity:

            ## Context
            - Current focus:
            - Key projects:

            ## Notes
            """
            try? template.write(to: profileFile, atomically: true, encoding: .utf8)
        }
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

    private var memorySearchTool: ToolDefinition {
        ToolDefinition(
            name: "memory_search",
            description: "Search across all .neo memory files for a keyword or phrase. Returns matching lines with file paths.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Text to search for (case-insensitive)")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional directory to search within, e.g. '.neo/memory/topics'. Defaults to '.neo'")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }
            guard case .object(let dict) = args,
                  case .string(let query) = dict["query"] else {
                return "Error: 'query' required"
            }
            let path: String?
            if case .string(let p) = dict["path"] { path = p } else { path = nil }

            let searchRoot = self.resolveNeoPath(path) ?? self.neoDirectory
            let lowerQuery = query.lowercased()
            var results: [String] = []
            let maxResults = 50

            self.searchFiles(in: searchRoot, query: lowerQuery, results: &results, maxResults: maxResults)

            if results.isEmpty {
                return "No matches found for '\(query)'"
            }
            return results.joined(separator: "\n")
        }
    }

    private func searchFiles(in directory: URL, query: String, results: inout [String], maxResults: Int) {
        guard results.count < maxResults else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard results.count < maxResults else { return }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                searchFiles(in: item, query: query, results: &results, maxResults: maxResults)
            } else if item.pathExtension == "md" || item.pathExtension == "txt" {
                guard let content = try? String(contentsOf: item, encoding: .utf8) else { continue }
                let relativePath = item.path.replacingOccurrences(of: baseDirectory.path + "/", with: "")
                let lines = content.components(separatedBy: "\n")
                for (lineNum, line) in lines.enumerated() {
                    guard results.count < maxResults else { return }
                    if line.lowercased().contains(query) {
                        results.append("\(relativePath):\(lineNum + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
    }

    private var memoryDeleteTool: ToolDefinition {
        ToolDefinition(
            name: "memory_delete",
            description: "Delete a memory file or a section within a file under .neo.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Path under .neo/ to delete, e.g. '.neo/memory/topics/old-topic.md'")
                    ]),
                    "section": .object([
                        "type": .string("string"),
                        "description": .string("Optional: delete only this section from the file instead of the whole file")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }
            guard case .object(let dict) = args,
                  case .string(let path) = dict["path"] else {
                return "Error: 'path' required"
            }
            let section: String?
            if case .string(let s) = dict["section"] { section = s } else { section = nil }

            guard let url = self.resolveNeoPath(path) else { return "Error: invalid .neo path" }

            if let section {
                // Delete section from file
                let content = try self.readString(at: url)
                guard !content.isEmpty else { return "File not found or empty" }
                let cleaned = self.removeSection(section, from: content)
                try self.writeString(cleaned, to: url)
                memoryLogger.info("memory_delete section '\(section, privacy: .public)' from \(url.lastPathComponent, privacy: .public)")
                return "Deleted section '\(section)' from \(url.lastPathComponent)"
            } else {
                // Delete entire file
                guard FileManager.default.fileExists(atPath: url.path) else { return "File not found" }
                try FileManager.default.removeItem(at: url)
                memoryLogger.info("memory_delete file: \(url.lastPathComponent, privacy: .public)")
                return "Deleted \(url.lastPathComponent)"
            }
        }
    }

    private func removeSection(_ section: String, from content: String) -> String {
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

        guard let start else { return content }
        let stop = end ?? lines.count
        var resultLines = Array(lines[0..<start])
        if stop < lines.count {
            resultLines.append(contentsOf: lines[stop...])
        }
        return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private var memoryGetYesterdayTool: ToolDefinition {
        ToolDefinition(
            name: "memory_get_yesterday",
            description: "Get yesterday's daily summary. Returns the daily report from .neo/reports/daily/ for the previous day, giving context about what was done.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "description": .string("Optional date in YYYY-MM-DD format. Defaults to yesterday.")
                    ])
                ])
            ]),
            skipPermission: true
        ) { [weak self] args in
            guard let self else { return "Error: MemoryToolProvider unavailable" }

            let targetDate: String
            if case .object(let dict) = args, case .string(let d) = dict["date"], !d.isEmpty {
                targetDate = d
            } else {
                let cal = Calendar.current
                let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                targetDate = fmt.string(from: yesterday)
            }

            let dailyFile = self.neoDirectory
                .appendingPathComponent("reports/daily/\(targetDate).md")

            if FileManager.default.fileExists(atPath: dailyFile.path) {
                let content = try self.readString(at: dailyFile)
                return content.isEmpty ? "Daily report for \(targetDate) is empty." : content
            }

            // Fall back to session log for that day
            let sessionFile = self.neoDirectory
                .appendingPathComponent("reports/sessions/\(targetDate).jsonl")

            if FileManager.default.fileExists(atPath: sessionFile.path) {
                let raw = try self.readString(at: sessionFile)
                let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
                if lines.isEmpty {
                    return "No activity found for \(targetDate)."
                }
                return "No daily summary yet for \(targetDate). Raw session log (\(lines.count) entries):\n\n\(raw)"
            }

            return "No data found for \(targetDate). No daily report or session log exists."
        }
    }
}

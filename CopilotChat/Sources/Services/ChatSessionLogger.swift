import Foundation
import os

/// Logs chat messages as JSONL to `.neo/reports/sessions/YYYY-MM-DD.jsonl`.
/// Rotates files at 500 lines. Loads recent history on startup.
public final class ChatSessionLogger: Sendable {

    private let sessionsDir: URL
    private let logger = Logger(subsystem: "CopilotChat", category: "SessionLogger")
    private let maxLines = 500
    private let historyCount = 50

    public init(workspaceURL: URL) {
        self.sessionsDir = workspaceURL
            .appendingPathComponent(".neo/reports/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true
        )
    }

    // MARK: - Logging

    /// Append a message entry to today's JSONL file.
    public func log(role: String, text: String, project: String? = nil) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "role": role,
            "text": text,
            "project": project ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let fileURL = currentFileURL()
        rotateIfNeeded(fileURL)

        let lineData = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                handle.closeFile()
            }
        } else {
            try? lineData.write(to: fileURL)
        }
    }

    // MARK: - History Loading

    /// Delete all session JSONL files.
    public func clearHistory() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jsonl" {
            try? fm.removeItem(at: file)
        }
        logger.info("Cleared all session history files")
    }

    /// Load the most recent messages across session files.
    /// Returns an array of (role, text, project, timestamp) tuples.
    public func loadHistory() -> [(role: String, text: String, project: String?, timestamp: Date)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) // newest first
        else { return [] }

        var results: [(role: String, text: String, project: String?, timestamp: Date)] = []
        let isoFormatter = ISO8601DateFormatter()

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .reversed() // newest lines last in file → reverse to get newest first

            for line in lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let role = obj["role"] as? String,
                      let text = obj["text"] as? String,
                      let tsStr = obj["ts"] as? String else { continue }

                // Stop at the last clear marker — don't show messages before it
                if role == "clear" { return results.reversed() }

                // Skip tool call entries — only restore user/assistant/system messages
                if role != "user" && role != "assistant" && role != "system" { continue }

                let project = (obj["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let ts = isoFormatter.date(from: tsStr) ?? Date()
                results.append((role: role, text: text, project: project, timestamp: ts))

                if results.count >= historyCount { break }
            }
            if results.count >= historyCount { break }
        }

        return results.reversed() // chronological order
    }

    // MARK: - Private

    private func currentFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = formatter.string(from: Date()) + ".jsonl"
        return sessionsDir.appendingPathComponent(name)
    }

    private func rotateIfNeeded(_ fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let lineCount = content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }.count

        if lineCount >= maxLines {
            // Rename current file with suffix and start fresh
            let stem = fileURL.deletingPathExtension().lastPathComponent
            var idx = 1
            var rotated: URL
            repeat {
                rotated = sessionsDir.appendingPathComponent("\(stem)-\(idx).jsonl")
                idx += 1
            } while FileManager.default.fileExists(atPath: rotated.path)

            try? FileManager.default.moveItem(at: fileURL, to: rotated)
        }
    }
}

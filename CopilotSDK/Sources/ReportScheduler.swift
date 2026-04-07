import Foundation
import os.log

private let schedLogger = Logger(subsystem: "com.copilot-ios.sdk", category: "ReportScheduler")

/// Checks for pending reports on app foreground and triggers the memory agent.
/// Runs at most once per day, after 6:00 AM local time.
public final class ReportScheduler: @unchecked Sendable {
    private let workspaceURL: URL
    private let subAgentProvider: SubAgentToolProvider
    private let triggerHour: Int  // hour in local time to start (default 6)

    public init(workspaceURL: URL, subAgentProvider: SubAgentToolProvider, triggerHour: Int = 6) {
        self.workspaceURL = workspaceURL
        self.subAgentProvider = subAgentProvider
        self.triggerHour = triggerHour
    }

    /// Call this on app foreground / session start. It checks if reports are needed and runs the memory agent.
    /// Non-blocking — spawns a background Task.
    public func checkAndRun() {
        Task {
            await runIfNeeded()
        }
    }

    /// Determine which reports are needed and run memory agent for each.
    private func runIfNeeded() async {
        let cal = Calendar.current
        let now = Date()

        // Only run after trigger hour
        guard cal.component(.hour, from: now) >= triggerHour else {
            schedLogger.debug("Before trigger hour (\(self.triggerHour)), skipping report check")
            return
        }

        // Check last run marker
        let markerFile = workspaceURL.appendingPathComponent(".neo/reports/.last-scheduled")
        let lastRunDate = readLastRun(markerFile)
        let todayStr = dateString(now)

        if lastRunDate == todayStr {
            schedLogger.debug("Already ran today (\(todayStr)), skipping")
            return
        }

        schedLogger.info("Starting scheduled report generation for \(todayStr)")

        // Build the task prompt based on what's needed
        let task = buildTask(now: now, calendar: cal)
        guard !task.isEmpty else {
            schedLogger.info("No reports needed")
            writeLastRun(markerFile, date: todayStr)
            return
        }

        let result = await subAgentProvider.runAgent(name: "memory", task: task)
        schedLogger.info("Report generation result: \(result.prefix(200))")

        // Mark as done for today
        writeLastRun(markerFile, date: todayStr)
    }

    private func buildTask(now: Date, calendar cal: Calendar) -> String {
        var tasks: [String] = []

        // Yesterday's daily report
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let yesterdayStr = dateString(yesterday)
        let dailyReport = workspaceURL
            .appendingPathComponent(".neo/reports/daily/\(yesterdayStr).md")
        let sessionLog = workspaceURL
            .appendingPathComponent(".neo/reports/sessions/\(yesterdayStr).jsonl")

        if !FileManager.default.fileExists(atPath: dailyReport.path)
            && FileManager.default.fileExists(atPath: sessionLog.path) {
            tasks.append("Generate daily report for \(yesterdayStr) from session log at .neo/reports/sessions/\(yesterdayStr).jsonl. Write to .neo/reports/daily/\(yesterdayStr).md")
        }

        // Weekly report on Monday
        if cal.component(.weekday, from: now) == 2 { // Monday
            let weekNum = cal.component(.weekOfYear, from: now)
            let year = cal.component(.yearForWeekOfYear, from: now)
            let weekStr = String(format: "%04d-W%02d", year, weekNum - 1) // last week
            let weeklyReport = workspaceURL
                .appendingPathComponent(".neo/reports/weekly/\(weekStr).md")
            if !FileManager.default.fileExists(atPath: weeklyReport.path) {
                tasks.append("Generate weekly report for \(weekStr). Read daily reports from the past 7 days and write to .neo/reports/weekly/\(weekStr).md")
            }
        }

        // Monthly report on 1st of month
        if cal.component(.day, from: now) == 1 {
            let lastMonth = cal.date(byAdding: .month, value: -1, to: now)!
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM"
            let monthStr = fmt.string(from: lastMonth)
            let monthlyReport = workspaceURL
                .appendingPathComponent(".neo/reports/monthly/\(monthStr).md")
            if !FileManager.default.fileExists(atPath: monthlyReport.path) {
                tasks.append("Generate monthly report for \(monthStr). Read weekly reports from last month and write to .neo/reports/monthly/\(monthStr).md")
            }
        }

        return tasks.joined(separator: "\n\n")
    }

    private func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private func readLastRun(_ file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeLastRun(_ file: URL, date: String) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? date.write(to: file, atomically: true, encoding: .utf8)
    }
}

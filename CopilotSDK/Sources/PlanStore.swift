import Foundation

// MARK: - PlanStore

/// Local persistence for plans and execution history.
/// Uses JSON files in a directory for simplicity.
public class PlanStore {
    
    /// All loaded plans.
    public private(set) var plans: [Plan] = []
    
    /// Root directory for plan storage.
    private let directory: URL
    
    /// Path to plans JSON file.
    private var plansFile: URL {
        directory.appendingPathComponent("plans.json")
    }
    
    /// Path to executions JSONL file (append-only).
    private var executionsFile: URL {
        directory.appendingPathComponent("executions.jsonl")
    }
    
    // MARK: - Init
    
    /// Create a PlanStore with the given directory.
    /// Pass a temp directory for testing.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            // Default to Documents/plans/
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.directory = docs.appendingPathComponent("plans")
        }
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        
        // Load on init
        load()

        // Seed default report plans on first use
        seedReportPlansIfNeeded()
    }
    
    // MARK: - CRUD
    
    /// Load plans from disk.
    public func load() {
        guard FileManager.default.fileExists(atPath: plansFile.path) else { return }
        do {
            let data = try Data(contentsOf: plansFile)
            plans = try JSONDecoder().decode([Plan].self, from: data)
        } catch {
            plans = []
        }
    }
    
    /// Save plans to disk.
    private func save() {
        do {
            let data = try JSONEncoder().encode(plans)
            try data.write(to: plansFile)
        } catch {
            // Log error in production
        }
    }
    
    /// Create a new plan.
    public func createPlan(_ plan: Plan) {
        plans.append(plan)
        save()
    }
    
    /// Update an existing plan.
    public func updatePlan(_ plan: Plan) {
        if let idx = plans.firstIndex(where: { $0.id == plan.id }) {
            var updated = plan
            updated.updatedAt = Date()
            plans[idx] = updated
            save()
        }
    }
    
    /// Delete a plan by ID.
    public func deletePlan(_ id: String) {
        plans.removeAll { $0.id == id }
        save()
    }
    
    // MARK: - Execution History
    
    /// Append an execution record (JSONL format).
    public func addExecution(_ execution: PlanExecution) {
        do {
            let data = try JSONEncoder().encode(execution)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            
            if FileManager.default.fileExists(atPath: executionsFile.path) {
                let handle = try FileHandle(forWritingTo: executionsFile)
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try line.data(using: .utf8)?.write(to: executionsFile)
            }
        } catch {
            // Log error in production
        }
    }
    
    /// Get execution history for a specific plan.
    public func getHistory(for planId: String) -> [PlanExecution] {
        guard FileManager.default.fileExists(atPath: executionsFile.path),
              let content = try? String(contentsOf: executionsFile, encoding: .utf8) else {
            return []
        }
        
        let decoder = JSONDecoder()
        return content
            .split(separator: "\n")
            .compactMap { line -> PlanExecution? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(PlanExecution.self, from: data)
            }
            .filter { $0.planId == planId }
    }
    
    /// Get all execution history.
    public func allHistory() -> [PlanExecution] {
        guard FileManager.default.fileExists(atPath: executionsFile.path),
              let content = try? String(contentsOf: executionsFile, encoding: .utf8) else {
            return []
        }
        
        let decoder = JSONDecoder()
        return content
            .split(separator: "\n")
            .compactMap { line -> PlanExecution? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(PlanExecution.self, from: data)
            }
    }
    
    // MARK: - Query
    
    /// Get plans that are due for execution (enabled + nextFireDate is in the past or now).
    public func duePlans() -> [Plan] {
        let now = Date()
        return plans.filter { plan in
            guard plan.enabled else { return false }
            guard let nextDate = plan.schedule.nextFireDate(after: now.addingTimeInterval(-86400)) else { return false }
            return nextDate <= now
        }
    }

    // MARK: - Seed Reports

    private static let reportPlanIds = [
        "report-daily", "report-weekly", "report-monthly"
    ]

    private func seedReportPlansIfNeeded() {
        let existingIds = Set(plans.map(\.id))
        guard !existingIds.contains("report-daily") else { return }

        let memoryTools = [
            "memory_read", "memory_append", "memory_write_section",
            "memory_list", "memory_search", "memory_get_yesterday"
        ]

        let daily = Plan(
            id: "report-daily",
            name: "Daily Report",
            prompt: """
            Generate yesterday's daily report.
            1. Use memory_list to check .neo/reports/sessions/ for yesterday's session log (YYYY-MM-DD.jsonl)
            2. Use memory_read to read the session log
            3. Summarize into sections: Summary, Tasks Completed, Key Decisions, Open Items
            4. Use memory_write_section to write each section to .neo/reports/daily/YYYY-MM-DD.md
            Keep it concise, under 500 words. If no session log exists, skip.
            """,
            schedule: .interval(seconds: 86400),
            model: "gpt-4.1-mini",
            enabled: true,
            tools: memoryTools
        )

        let weekly = Plan(
            id: "report-weekly",
            name: "Weekly Report (Monday)",
            prompt: """
            Generate last week's weekly report. Only run on Mondays.
            1. Use memory_list to find daily reports from the past 7 days in .neo/reports/daily/
            2. Use memory_read to read each daily report
            3. Summarize into: Week Summary, Accomplishments, Projects Progress, Next Week
            4. Write to .neo/reports/weekly/YYYY-WXX.md using memory_write_section
            If no daily reports exist, skip.
            """,
            schedule: .interval(seconds: 604800),
            model: "gpt-4.1-mini",
            enabled: true,
            tools: memoryTools
        )

        let monthly = Plan(
            id: "report-monthly",
            name: "Monthly Report (1st)",
            prompt: """
            Generate last month's monthly report. Only run on the 1st of the month.
            1. Use memory_list to find weekly reports in .neo/reports/weekly/
            2. Use memory_read to read weekly reports from last month
            3. Summarize into: Month Summary, Key Milestones, Patterns, Goals Review
            4. Write to .neo/reports/monthly/YYYY-MM.md using memory_write_section
            If no weekly reports exist, skip.
            """,
            schedule: .interval(seconds: 2592000),
            model: "gpt-4.1-mini",
            enabled: true,
            tools: memoryTools
        )

        createPlan(daily)
        createPlan(weekly)
        createPlan(monthly)
    }
}

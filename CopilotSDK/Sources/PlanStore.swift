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

    private func seedReportPlansIfNeeded() {
        let existingIds = Set(plans.map(\.id))
        guard !existingIds.contains("memory-reports") else { return }

        let plan = Plan(
            id: "memory-reports",
            name: "Memory Reports",
            prompt: """
            Run the memory sub-agent to generate reports. Use task tool with agent "memory" and the following task:

            Generate memory reports for today. Check the current date and:

            1. ALWAYS: Generate yesterday's daily report
               - Read .neo/reports/sessions/ for yesterday's JSONL log
               - Summarize into .neo/reports/daily/YYYY-MM-DD.md (Summary, Tasks, Decisions, Open Items)
               - Skip if no session log exists or daily report already exists

            2. IF MONDAY: Also generate last week's weekly report
               - Read daily reports from past 7 days in .neo/reports/daily/
               - Write .neo/reports/weekly/YYYY-WXX.md (Week Summary, Accomplishments, Projects, Next Week)

            3. IF 1st OF MONTH: Also generate last month's monthly report
               - Read weekly reports from .neo/reports/weekly/
               - Write .neo/reports/monthly/YYYY-MM.md (Month Summary, Milestones, Patterns, Goals)

            4. IF JANUARY 1st: Also generate last year's yearly report
               - Read monthly reports from .neo/reports/monthly/
               - Write .neo/reports/yearly/YYYY.md (Year Summary, Major Milestones, Growth, Next Year Goals)
            """,
            schedule: .interval(seconds: 86400),
            model: "gpt-4.1-mini",
            enabled: true,
            tools: ["task"]
        )

        createPlan(plan)
    }
}

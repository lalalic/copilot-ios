#if os(iOS)
import Foundation
import BackgroundTasks
import UserNotifications

// MARK: - PlanExecutor

/// Executes plans via BGTaskScheduler or manual trigger.
/// Connects to the relay, runs the plan prompt, collects results.
public class PlanExecutor: @unchecked Sendable {
    
    public static let shared = PlanExecutor()
    
    // MARK: - Task Identifiers
    
    public static let processTaskId = "com.neox.plan.process"
    public static let refreshTaskId = "com.neox.plan.refresh"
    
    // MARK: - Dependencies
    
    private var planStore: PlanStore?
    private var relayHost: String = "10.0.0.111"
    private var relayPort: UInt16 = 8765
    private var userId: String?
    private var toolsBuilder: (@Sendable () -> [ToolDefinition])?
    
    private init() {}
    
    // MARK: - Configuration
    
    /// Configure the executor with dependencies.
    public func configure(
        planStore: PlanStore,
        relayHost: String,
        relayPort: UInt16,
        userId: String? = nil,
        toolsBuilder: (@Sendable () -> [ToolDefinition])? = nil
    ) {
        self.planStore = planStore
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.userId = userId
        self.toolsBuilder = toolsBuilder
    }
    
    // MARK: - BGTask Registration
    
    /// Register BGTask handlers. Call this from App init / didFinishLaunching.
    public func registerBGTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleProcessingTask(task as! BGProcessingTask)
        }
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleRefreshTask(task as! BGAppRefreshTask)
        }
    }
    
    // MARK: - Task Handlers
    
    /// Handle a BGProcessingTask — find and execute the next due plan.
    private func handleProcessingTask(_ task: BGProcessingTask) {
        guard let planStore else {
            task.setTaskCompleted(success: false)
            return
        }
        
        let duePlans = planStore.duePlans()
        guard let plan = duePlans.first else {
            task.setTaskCompleted(success: true)
            scheduleNextCheck()
            return
        }
        
        nonisolated(unsafe) let bgTask = task
        let executor = self
        let execTask = Task {
            await executor.executePlan(plan)
        }
        
        task.expirationHandler = {
            execTask.cancel()
        }
        
        Task {
            _ = await execTask.result
            bgTask.setTaskCompleted(success: true)
            executor.scheduleNextCheck()
        }
    }
    
    /// Handle a BGAppRefreshTask — check if plans are due and schedule processing.
    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        guard let planStore else {
            task.setTaskCompleted(success: true)
            return
        }
        
        let duePlans = planStore.duePlans()
        if !duePlans.isEmpty {
            // Schedule a processing task immediately
            let request = BGProcessingTaskRequest(identifier: Self.processTaskId)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            request.earliestBeginDate = Date()
            try? BGTaskScheduler.shared.submit(request)
        }
        
        // Schedule next refresh
        scheduleRefresh()
        task.setTaskCompleted(success: true)
    }
    
    // MARK: - Execute Plan
    
    /// Execute a plan: connect to relay, run prompt, collect result.
    /// Can be called from foreground (manual run) or background (BGTask).
    public func executePlan(_ plan: Plan) async {
        guard let planStore else { return }
        
        var execution = PlanExecution(planId: plan.id)
        planStore.addExecution(execution)
        
        do {
            // 1. Connect to relay
            let transport = WebSocketTransport(host: relayHost, port: relayPort)
            let client = CopilotClient(transport: transport)
            try await client.start()
            
            // 2. Create session with tools if plan specifies them
            let planTools: [ToolDefinition]
            if !plan.tools.isEmpty, let builder = self.toolsBuilder {
                let allTools = builder()
                let allowed = Set(plan.tools)
                planTools = allTools.filter { allowed.contains($0.name) }
            } else {
                planTools = []
            }

            let config = SessionConfig(
                model: plan.model.isEmpty ? "gpt-4.1" : plan.model,
                tools: planTools.isEmpty ? nil : planTools,
                userId: self.userId
            )
            let session = try await client.createSession(config: config)
            
            // 3. Send plan prompt and wait for response
            let resultText = try await session.sendAndWait(
                prompt: plan.prompt,
                timeout: 120
            ) ?? "No output"
            
            // 4. Calculate cost (rough estimate since we don't have token counts from sendAndWait)
            let cost: Double = 0 // Token tracking happens on the main chat flow
            
            // 5. Record result
            execution.complete(
                result: resultText,
                tokensUsed: nil,
                cost: cost
            )
            planStore.addExecution(execution)
            
            // 6. Post notification
            postCompletionNotification(plan: plan, result: resultText, cost: cost)
            
            // 7. Disconnect
            try? await session.close()
            
        } catch {
            execution.fail(error: error.localizedDescription)
            planStore.addExecution(execution)
            postFailureNotification(plan: plan, error: error.localizedDescription)
        }
    }
    
    // MARK: - Scheduling
    
    /// Schedule the next BGProcessingTask for the earliest due plan.
    public func schedulePlan(_ plan: Plan) {
        guard plan.enabled, let nextDate = plan.schedule.nextFireDate() else { return }
        
        let request = BGProcessingTaskRequest(identifier: Self.processTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextDate
        
        try? BGTaskScheduler.shared.submit(request)
    }
    
    /// Schedule the next refresh check.
    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        try? BGTaskScheduler.shared.submit(request)
    }
    
    /// Schedule next processing based on earliest due plan.
    public func scheduleNextCheck() {
        guard let planStore else { return }
        
        let nextDue = planStore.plans
            .filter { $0.enabled }
            .compactMap { plan -> (Plan, Date)? in
                guard let next = plan.schedule.nextFireDate() else { return nil }
                return (plan, next)
            }
            .min(by: { $0.1 < $1.1 })
        
        guard let (_, nextDate) = nextDue else { return }
        
        let request = BGProcessingTaskRequest(identifier: Self.processTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextDate
        
        try? BGTaskScheduler.shared.submit(request)
    }
    
    /// Cancel all scheduled tasks for a plan.
    public func cancelPlan(_ planId: String) {
        // BGTaskScheduler doesn't support per-plan cancellation,
        // but we can reschedule based on remaining plans
        scheduleNextCheck()
    }
    
    // MARK: - Notifications
    
    private func postCompletionNotification(plan: Plan, result: String, cost: Double) {
        let content = UNMutableNotificationContent()
        content.title = "✅ \(plan.name)"
        content.body = String(result.prefix(200))
        content.sound = .default
        content.categoryIdentifier = "PLAN_RESULT"
        
        if cost > 0 {
            content.subtitle = CostCalculator.formatCost(cost)
        }
        
        let request = UNNotificationRequest(
            identifier: "plan-\(plan.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
    
    private func postFailureNotification(plan: Plan, error: String) {
        let content = UNMutableNotificationContent()
        content.title = "❌ \(plan.name)"
        content.body = error
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "plan-fail-\(plan.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Response Collector

/// Actor to safely collect streaming response data from event handlers.
private actor ResponseCollector {
    var resultText = ""
    var promptTokens = 0
    var completionTokens = 0
    
    func appendText(_ text: String) {
        resultText += text
    }
    
    func addTokens(prompt: Int, completion: Int) {
        promptTokens += prompt
        completionTokens += completion
    }
}
#endif // os(iOS)

import SwiftUI
import CopilotSDK

// MARK: - Plan Manager View

/// Main view for managing plans — list, create, edit, run.
public struct PlanManagerView: View {
    @State private var store: PlanStore
    @State private var showCreateSheet = false
    @State private var selectedPlan: Plan?
    
    /// Called when user taps "Run Now" on a plan. Dismisses sheets and executes.
    public var onRunPlan: ((Plan) -> Void)?
    
    public init(store: PlanStore = PlanStore(), onRunPlan: ((Plan) -> Void)? = nil) {
        self._store = State(initialValue: store)
        self.onRunPlan = onRunPlan
    }
    
    public var body: some View {
        List {
            if store.plans.isEmpty {
                ContentUnavailableView(
                    "No Plans",
                    systemImage: "calendar.badge.clock",
                    description: Text("Create a plan to run tasks on a schedule.")
                )
            } else {
                ForEach(store.plans) { plan in
                    PlanRowView(plan: plan, store: store, onTap: {
                        selectedPlan = plan
                    }, onRunNow: onRunPlan != nil ? {
                        onRunPlan?(plan)
                    } : nil)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        store.deletePlan(store.plans[index].id)
                    }
                }
            }
        }
        .navigationTitle("Plans")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    PlanHistoryView(planStore: store)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showCreateSheet = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            PlanEditView(store: store, mode: .create)
        }
        .sheet(item: $selectedPlan) { plan in
            PlanEditView(store: store, mode: .edit(plan))
        }
    }
}

// MARK: - Plan Row

struct PlanRowView: View {
    let plan: Plan
    let store: PlanStore
    let onTap: () -> Void
    var onRunNow: (() -> Void)?
    
    var body: some View {
        HStack {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(plan.name)
                            .font(.headline)
                        if !plan.enabled {
                            Text("OFF")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    Text(plan.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        scheduleLabel
                        Text("•")
                            .foregroundStyle(.quaternary)
                        Text(plan.model)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if let onRunNow {
                Button {
                    onRunNow()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Run Now")
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.quaternary)
                .font(.caption)
        }
        .swipeActions(edge: .leading) {
            if let onRunNow {
                Button(action: onRunNow) {
                    Label("Run Now", systemImage: "play.fill")
                }
                .tint(.green)
            }
        }
    }
    
    private var scheduleLabel: some View {
        Group {
            switch plan.schedule {
            case .manual:
                Label("Manual", systemImage: "hand.tap")
            case .once:
                Label("Once", systemImage: "1.circle")
            case .interval(let seconds):
                Label(formatInterval(seconds), systemImage: "repeat")
            case .cron(let expr, _):
                Label(expr, systemImage: "clock")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    
    private func formatInterval(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

// MARK: - Plan Edit View

struct PlanEditView: View {
    let store: PlanStore
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String
    @State private var prompt: String
    @State private var scheduleType: ScheduleType
    @State private var intervalMinutes: Int
    @State private var onceDate: Date
    @State private var model: String
    @State private var enabled: Bool
    @State private var requiresApproval: Bool
    @State private var maxTokenBudget: Int
    
    enum Mode: Identifiable {
        case create
        case edit(Plan)
        
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let plan): return plan.id
            }
        }
    }
    
    enum ScheduleType: String, CaseIterable {
        case manual = "Manual"
        case once = "Once"
        case interval = "Interval"
    }
    
    init(store: PlanStore, mode: Mode) {
        self.store = store
        self.mode = mode
        
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _prompt = State(initialValue: "")
            _scheduleType = State(initialValue: .manual)
            _intervalMinutes = State(initialValue: 60)
            _onceDate = State(initialValue: Date(timeIntervalSinceNow: 3600))
            _model = State(initialValue: "gpt-4.1")
            _enabled = State(initialValue: true)
            _requiresApproval = State(initialValue: false)
            _maxTokenBudget = State(initialValue: 10000)
        case .edit(let plan):
            _name = State(initialValue: plan.name)
            _prompt = State(initialValue: plan.prompt)
            _model = State(initialValue: plan.model)
            _enabled = State(initialValue: plan.enabled)
            _requiresApproval = State(initialValue: plan.requiresApproval)
            _maxTokenBudget = State(initialValue: plan.maxTokenBudget)
            
            switch plan.schedule {
            case .manual:
                _scheduleType = State(initialValue: .manual)
                _intervalMinutes = State(initialValue: 60)
                _onceDate = State(initialValue: Date(timeIntervalSinceNow: 3600))
            case .once(let at):
                _scheduleType = State(initialValue: .once)
                _intervalMinutes = State(initialValue: 60)
                _onceDate = State(initialValue: at)
            case .interval(let seconds):
                _scheduleType = State(initialValue: .interval)
                _intervalMinutes = State(initialValue: seconds / 60)
                _onceDate = State(initialValue: Date(timeIntervalSinceNow: 3600))
            case .cron:
                _scheduleType = State(initialValue: .manual)
                _intervalMinutes = State(initialValue: 60)
                _onceDate = State(initialValue: Date(timeIntervalSinceNow: 3600))
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Plan") {
                    TextField("Name", text: $name)
                    
                    VStack(alignment: .leading) {
                        Text("Prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $prompt)
                            .frame(minHeight: 100)
                    }
                }
                
                Section("Schedule") {
                    Picker("Type", selection: $scheduleType) {
                        ForEach(ScheduleType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    
                    if scheduleType == .interval {
                        Stepper("Every \(intervalMinutes) min", value: $intervalMinutes, in: 1...10080)
                    }
                    
                    if scheduleType == .once {
                        DatePicker("Run at", selection: $onceDate, in: Date()...)
                    }
                }
                
                Section("Model") {
                    Picker("Model", selection: $model) {
                        ForEach(ModelCatalog.allModels) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                }
                
                Section("Options") {
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Requires Approval", isOn: $requiresApproval)
                    Stepper("Max Tokens: \(maxTokenBudget)", value: $maxTokenBudget, in: 1000...100000, step: 1000)
                }
                
                if case .edit(let plan) = mode {
                    Section {
                        Button("Delete Plan", role: .destructive) {
                            store.deletePlan(plan.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isCreate ? "New Plan" : "Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePlan()
                        dismiss()
                    }
                    .disabled(name.isEmpty || prompt.isEmpty)
                }
            }
        }
    }
    
    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }
    
    private var schedule: PlanSchedule {
        switch scheduleType {
        case .manual: return .manual
        case .once: return .once(at: onceDate)
        case .interval: return .interval(seconds: intervalMinutes * 60)
        }
    }
    
    private func savePlan() {
        switch mode {
        case .create:
            let plan = Plan(
                name: name,
                prompt: prompt,
                schedule: schedule,
                model: model,
                enabled: enabled,
                requiresApproval: requiresApproval,
                maxTokenBudget: maxTokenBudget
            )
            store.createPlan(plan)
            PlanExecutor.shared.schedulePlan(plan)
        case .edit(var plan):
            plan.name = name
            plan.prompt = prompt
            plan.schedule = schedule
            plan.model = model
            plan.enabled = enabled
            plan.requiresApproval = requiresApproval
            plan.maxTokenBudget = maxTokenBudget
            store.updatePlan(plan)
            PlanExecutor.shared.schedulePlan(plan)
        }
    }
}

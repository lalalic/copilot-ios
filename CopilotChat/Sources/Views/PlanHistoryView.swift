import SwiftUI
import CopilotSDK

// MARK: - Plan History View

/// Shows execution history for a plan or all plans.
public struct PlanHistoryView: View {
    let planStore: PlanStore
    let planId: String? // nil = all plans
    
    public init(planStore: PlanStore, planId: String? = nil) {
        self.planStore = planStore
        self.planId = planId
    }
    
    private var executions: [PlanExecution] {
        let all = planId != nil
            ? planStore.getHistory(for: planId!)
            : planStore.allHistory()
        return all.sorted { $0.startedAt > $1.startedAt }
    }
    
    public var body: some View {
        List {
            if executions.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Plan executions will appear here.")
                )
            } else {
                ForEach(executions) { execution in
                    ExecutionRowView(
                        execution: execution,
                        planName: planName(for: execution.planId)
                    )
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func planName(for planId: String) -> String {
        planStore.plans.first { $0.id == planId }?.name ?? "Unknown Plan"
    }
}

// MARK: - Execution Row

private struct ExecutionRowView: View {
    let execution: PlanExecution
    let planName: String
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                
                Text(planName)
                    .font(.subheadline.weight(.semibold))
                
                Spacer()
                
                Text(execution.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // Duration + cost
            HStack(spacing: 12) {
                if let completed = execution.completedAt {
                    let duration = completed.timeIntervalSince(execution.startedAt)
                    Label(formatDuration(duration), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if let tokens = execution.tokensUsed {
                    Label("\(tokens.promptTokens + tokens.completionTokens) tokens", systemImage: "number")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if let cost = execution.cost {
                    Label(CostCalculator.formatCost(cost), systemImage: "dollarsign.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Status badge
            if execution.status == .failed, let error = execution.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            
            // Result (expandable)
            if let result = execution.result, !result.isEmpty {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    HStack {
                        Text(isExpanded ? "Hide Result" : "Show Result")
                            .font(.caption)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                
                if isExpanded {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusIcon: String {
        switch execution.status {
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .awaitingApproval: return "hand.raised.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch execution.status {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .awaitingApproval: return .yellow
        }
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        }
    }
}

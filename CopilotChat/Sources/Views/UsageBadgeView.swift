import SwiftUI
import CopilotSDK

// MARK: - Usage Badge View

/// Compact badge showing session cost and balance.
/// Designed to go in a navigation bar toolbar.
public struct UsageBadgeView: View {
    @ObservedObject private var tracker: UsageTracker
    @State private var showDetail = false

    public init(tracker: UsageTracker) {
        self.tracker = tracker
    }

    public var body: some View {
        Button(action: { showDetail = true }) {
            HStack(spacing: 4) {
                if tracker.sessionCost > 0 {
                    Text(CostCalculator.formatCost(tracker.sessionCost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(tracker.isLowBalance ? .orange : .secondary)
                } else {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(tracker.isLowBalance ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
        .sheet(isPresented: $showDetail) {
            UsageDetailView(tracker: tracker)
        }
    }
}

// MARK: - Usage Detail View

/// Full-screen usage breakdown shown when tapping the badge.
public struct UsageDetailView: View {
    @ObservedObject private var tracker: UsageTracker
    @Environment(\.dismiss) private var dismiss

    public init(tracker: UsageTracker) {
        self.tracker = tracker
    }

    public var body: some View {
        NavigationStack {
            List {
                // Balance section
                Section("Balance") {
                    HStack {
                        Label("Credits", systemImage: "dollarsign.circle.fill")
                        Spacer()
                        Text(String(format: "$%.2f", tracker.balance))
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(balanceColor)
                    }
                    if tracker.hasInsufficientBalance {
                        Label("No credits remaining", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else if tracker.isLowBalance {
                        Label("Low balance", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                // Session section
                Section("This Session") {
                    LabeledRow(label: "Cost", value: CostCalculator.formatCost(tracker.sessionCost))
                    LabeledRow(label: "Tokens", value: formatTokens(tracker.sessionTokens))
                }

                // Per-model breakdown
                if !tracker.sessionUsageByModel.isEmpty {
                    Section("Models Used") {
                        ForEach(tracker.sessionUsageByModel.keys.sorted(), id: \.self) { model in
                            if let usage = tracker.sessionUsageByModel[model] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model)
                                        .font(.caption.monospaced())
                                    HStack {
                                        Text("\(usage.promptTokens + usage.completionTokens) tokens")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(CostCalculator.formatCost(usage.cost))
                                            .font(.caption2.monospacedDigit())
                                    }
                                }
                            }
                        }
                    }
                }

                // Lifetime section
                Section("Lifetime") {
                    LabeledRow(label: "Total Cost", value: CostCalculator.formatCost(tracker.lifetimeCost))
                    LabeledRow(label: "Total Tokens", value: formatTokens(tracker.lifetimeTokens))
                }
            }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var balanceColor: Color {
        if tracker.hasInsufficientBalance { return .red }
        if tracker.isLowBalance { return .orange }
        return .primary
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Labeled Row

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}

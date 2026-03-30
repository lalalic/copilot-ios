import SwiftUI

// MARK: - Tool Activity View

/// Displays inline tool call status indicators.
/// Shows a collapsible list of active and completed tool calls.
public struct ToolActivityView: View {

    let toolCalls: [ToolCallInfo]
    @State private var isExpanded = false

    public init(toolCalls: [ToolCallInfo]) {
        self.toolCalls = toolCalls
    }

    public var body: some View {
        if !toolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // Header — tap to expand/collapse
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                // Expanded list
                if isExpanded {
                    ForEach(toolCalls) { call in
                        ToolCallRow(call: call)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(platformGray6.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
        }
    }

    private var summaryText: String {
        let running = toolCalls.filter { $0.status == .running }.count
        let completed = toolCalls.filter { $0.status == .completed }.count
        let total = toolCalls.count

        if running > 0 {
            return "Running \(running) of \(total) tools..."
        } else {
            return "\(completed) tools completed"
        }
    }
}

// MARK: - Tool Call Row

private struct ToolCallRow: View {
    let call: ToolCallInfo

    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            Group {
                switch call.status {
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                }
            }
            .frame(width: 16, height: 16)

            // Tool name
            Text(call.name)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)

            Spacer()

            // Result preview
            if let result = call.result {
                Text(result.prefix(40) + (result.count > 40 ? "..." : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

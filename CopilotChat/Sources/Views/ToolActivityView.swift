import SwiftUI

// MARK: - Tool Activity View

/// Shows only the currently running tool call as a minimal single-line indicator.
public struct ToolActivityView: View {

    let toolCalls: [ToolCallInfo]

    public init(toolCalls: [ToolCallInfo]) {
        self.toolCalls = toolCalls
    }

    public var body: some View {
        if let current = toolCalls.last(where: { $0.status == .running }) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(current.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

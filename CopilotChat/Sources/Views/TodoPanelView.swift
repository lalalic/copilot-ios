import SwiftUI

// MARK: - Todo Panel View

/// Displays the task list from `manage_todo_list` tool above the input bar.
/// Shows a collapsible panel with task items and their status icons.
public struct TodoPanelView: View {

    let items: [TodoItem]
    @State private var isExpanded = true

    public init(items: [TodoItem]) {
        self.items = items
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.blue)

                        Text("Tasks")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                        .padding(.horizontal, 12)

                    // Task list
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            TodoRow(item: item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(platformGray5)
                            .frame(height: 2)

                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geo.size.width * progress, height: 2)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 2)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Computed

    private var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }

    private var progress: CGFloat {
        items.isEmpty ? 0 : CGFloat(completedCount) / CGFloat(items.count)
    }

    private var progressText: String {
        "\(completedCount)/\(items.count)"
    }
}

// MARK: - Todo Row

private struct TodoRow: View {
    let item: TodoItem

    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            Text(item.statusIcon)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
                .frame(width: 16)

            // Title
            Text(item.title)
                .font(.caption)
                .foregroundStyle(item.status == .completed ? .secondary : .primary)
                .strikethrough(item.status == .completed)
                .lineLimit(1)

            Spacer()

            // In-progress indicator
            if item.status == .inProgress {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch item.status {
        case .notStarted: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}

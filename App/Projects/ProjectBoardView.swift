import IndexKit
import SwiftUI

/// Per-project Kanban: dependency-aware columns computed from the same
/// task rows the timeline schedules. Blocked = waits on an unchecked
/// task's ^id; Ready = actionable now; Done = checked.
struct ProjectBoardView: View {
    let service: VaultIndexService
    let tasks: [TaskRecord]

    private struct Column: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let tint: Color
        let tasks: [TaskRecord]
    }

    private var columns: [Column] {
        let unfinishedBlockIds = Set(tasks.filter { !$0.checked }.compactMap(\.blockId))
        func isBlocked(_ task: TaskRecord) -> Bool {
            (task.dependsOn ?? "")
                .split(separator: " ")
                .contains { unfinishedBlockIds.contains(String($0)) }
        }
        let open = tasks.filter { !$0.checked && $0.parentId == nil }
        return [
            Column(
                id: "blocked", title: "Blocked", systemImage: "hand.raised",
                tint: .orange, tasks: open.filter(isBlocked)
            ),
            Column(
                id: "ready", title: "Ready", systemImage: "bolt",
                tint: .blue, tasks: open.filter { !isBlocked($0) }
            ),
            Column(
                id: "done", title: "Done", systemImage: "checkmark.circle",
                tint: .green, tasks: tasks.filter { $0.checked && $0.parentId == nil }
            ),
        ]
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(columns) { column in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(column.title) (\(column.tasks.count))", systemImage: column.systemImage)
                            .font(.headline)
                            .foregroundStyle(column.tint)
                        ForEach(column.tasks) { task in
                            card(task, tint: column.tint)
                        }
                        if column.tasks.isEmpty {
                            Text("Empty")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(10)
                    .frame(width: 250, alignment: .top)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }

    private func card(_ task: TaskRecord, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    Task { await service.toggle(task) }
                } label: {
                    Image(systemName: task.checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.checked ? Color.secondary : tint)
                }
                .buttonStyle(.plain)
                Text(task.text)
                    .strikethrough(task.checked)
                    .font(.callout)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if let priority = task.priority {
                    Text("P\(priority)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(priority <= 2 ? .red : .secondary)
                }
                if let due = task.dueDate {
                    Label(due, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if task.dependsOn != nil {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 22)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

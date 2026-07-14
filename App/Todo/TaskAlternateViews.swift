import IndexKit
import SwiftUI
import TaskEngine

/// Kanban board: one column per smart bucket, cards over the same dataset.
struct TaskBoardView: View {
    let grouped: [SmartBucket: [TaskRecord]]
    let subtaskProgress: [String: (done: Int, total: Int)]
    let onComplete: (TaskRecord) -> Void

    private static let columns: [(SmartBucket, String)] = [
        (.overdue, "Overdue"), (.today, "Today"), (.upcoming, "Upcoming"), (.inbox, "Inbox"),
    ]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Self.columns, id: \.0) { bucket, title in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(bucket == .overdue ? .red : .secondary)
                        ForEach(grouped[bucket] ?? []) { task in
                            TaskCard(task: task, progress: subtaskProgress[task.id], onComplete: onComplete)
                        }
                        if (grouped[bucket] ?? []).isEmpty {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 230, alignment: .topLeading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(12)
        }
    }
}

/// Agenda: chronological sections by due date; undated at the end.
struct TaskAgendaView: View {
    let tasks: [TaskRecord]
    let onComplete: (TaskRecord) -> Void

    private var byDate: [(String, [TaskRecord])] {
        let dated = Dictionary(grouping: tasks.filter { $0.dueDate != nil }) { $0.dueDate! }
        var sections = dated.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let undated = tasks.filter { $0.dueDate == nil }
        if !undated.isEmpty {
            sections.append(("No date", undated))
        }
        return sections
    }

    var body: some View {
        List {
            ForEach(byDate, id: \.0) { date, tasks in
                Section(date) {
                    ForEach(tasks) { task in
                        AgendaRow(task: task, onComplete: onComplete)
                    }
                }
            }
        }
    }
}

/// Eisenhower matrix: urgent = overdue/today, important = p1/p2.
struct TaskMatrixView: View {
    let tasks: [TaskRecord]
    let onComplete: (TaskRecord) -> Void

    private func quadrant(urgent: Bool, important: Bool) -> [TaskRecord] {
        tasks.filter { task in
            let bucket = SmartBuckets.bucket(dueDate: task.dueDate, startDate: task.startDate)
            let isUrgent = bucket == .overdue || bucket == .today
            let isImportant = (task.priority ?? 4) <= 2
            return isUrgent == urgent && isImportant == important
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                quadrantView("Do", subtitle: "urgent · important", tint: .red,
                             tasks: quadrant(urgent: true, important: true))
                quadrantView("Schedule", subtitle: "important", tint: .blue,
                             tasks: quadrant(urgent: false, important: true))
            }
            GridRow {
                quadrantView("Delegate", subtitle: "urgent", tint: .orange,
                             tasks: quadrant(urgent: true, important: false))
                quadrantView("Eliminate?", subtitle: "neither", tint: .gray,
                             tasks: quadrant(urgent: false, important: false))
            }
        }
        .padding(12)
    }

    private func quadrantView(
        _ title: String, subtitle: String, tint: Color, tasks: [TaskRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(tasks.count)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tasks) { task in
                        TaskCard(task: task, progress: nil, onComplete: onComplete)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Shared pieces

struct TaskCard: View {
    let task: TaskRecord
    let progress: (done: Int, total: Int)?
    let onComplete: (TaskRecord) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                onComplete(task)
            } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.text).font(.callout)
                HStack(spacing: 6) {
                    if let due = task.dueDate {
                        Text(due)
                    }
                    PriorityChip(priority: task.priority)
                    if let progress {
                        Text("\(progress.done)/\(progress.total)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AgendaRow: View {
    let task: TaskRecord
    let onComplete: (TaskRecord) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onComplete(task)
            } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(.plain)
            Text(task.text)
            Spacer()
            PriorityChip(priority: task.priority)
        }
    }
}

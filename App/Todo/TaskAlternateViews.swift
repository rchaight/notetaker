import IndexKit
import SwiftUI
import TaskEngine

/// Kanban board: one column per smart bucket, cards over the same dataset.
struct TaskBoardView: View {
    let grouped: [SmartBucket: [TaskRecord]]
    let subtaskProgress: [String: (done: Int, total: Int)]
    let onComplete: (TaskRecord) -> Void
    /// Drop-to-reschedule: nil ISO day clears the due date (Inbox).
    var onReschedule: (TaskRecord, String?) -> Void = { _, _ in }

    private static let columns: [(SmartBucket, String)] = [
        (.overdue, "Overdue"), (.today, "Today"), (.upcoming, "Upcoming"), (.inbox, "Inbox"),
    ]

    /// The due date a card acquires when dropped on a column. Overdue is
    /// not a target (nil tuple = reject the drop).
    static func dropDue(for bucket: SmartBucket, calendar: Calendar = .current) -> String?? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        switch bucket {
        case .today:
            return .some(formatter.string(from: Date()))
        case .upcoming:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            return .some(formatter.string(from: tomorrow))
        case .inbox:
            return .some(nil)
        case .overdue:
            return nil
        }
    }

    private func allTasks() -> [TaskRecord] {
        grouped.values.flatMap(\.self)
    }

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
                                .draggable(task.id)
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
                    .dropDestination(for: String.self) { ids, _ in
                        guard case let .some(due) = Self.dropDue(for: bucket) else { return false }
                        let tasks = allTasks()
                        var accepted = false
                        for id in ids {
                            if let task = tasks.first(where: { $0.id == id }) {
                                onReschedule(task, due)
                                accepted = true
                            }
                        }
                        return accepted
                    }
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
    var onReschedule: (TaskRecord, String?) -> Void = { _, _ in }

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
            ForEach(byDate, id: \.0) { date, sectionTasks in
                Section(date) {
                    ForEach(sectionTasks) { task in
                        AgendaRow(task: task, onComplete: onComplete)
                            .draggable(task.id)
                    }
                }
                .dropDestination(for: String.self) { ids, _ in
                    // "No date" section clears the due date.
                    let due: String? = date == "No date" ? nil : date
                    var accepted = false
                    for id in ids {
                        if let task = tasks.first(where: { $0.id == id }) {
                            onReschedule(task, due)
                            accepted = true
                        }
                    }
                    return accepted
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

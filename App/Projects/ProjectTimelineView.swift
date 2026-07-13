import Charts
import IndexKit
import ProjectKit
import SwiftUI

/// M7a read-only Gantt: one bar per top-level task, scheduled by the CPM
/// engine (explicit dates win; dependencies cascade). Critical path in
/// orange, done in green, `#milestone` tasks as diamonds. Scrolls
/// horizontally; zoom picks the visible span.
struct ProjectTimelineView: View {
    let project: NoteRecord
    let tasks: [TaskRecord]

    @State private var zoom: Zoom = .week

    enum Zoom: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }

        var visibleSeconds: TimeInterval {
            switch self {
            case .day: 14 * 86400
            case .week: 56 * 86400
            case .month: 180 * 86400
            }
        }
    }

    var body: some View {
        let nodes = timelineNodes()
        if nodes.isEmpty {
            ContentUnavailableView(
                "Nothing to Chart",
                systemImage: "chart.gantt",
                description: Text("Give tasks dates (>due, ~start) or dependencies (^id, blockedby:^id).")
            )
        } else if let scheduled = ProjectSchedule.schedule(nodes) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Zoom", selection: $zoom) {
                        ForEach(Zoom.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    Spacer()
                    legend
                }
                chart(scheduled)
            }
            .padding()
        } else {
            ContentUnavailableView(
                "Dependency Cycle",
                systemImage: "exclamationmark.triangle",
                description: Text("Tasks reference each other in a loop — break one blockedby:/depends: link.")
            )
        }
    }

    private func chart(_ scheduled: [ScheduledTask]) -> some View {
        Chart(scheduled) { bar in
            if isMilestone(bar) {
                PointMark(
                    x: .value("Date", date(for: bar.end)),
                    y: .value("Task", bar.node.title)
                )
                .symbol(.diamond)
                .symbolSize(180)
                .foregroundStyle(.purple)
            } else {
                BarMark(
                    xStart: .value("Start", date(for: bar.start)),
                    xEnd: .value("End", date(for: bar.end + 1)),
                    y: .value("Task", bar.node.title)
                )
                .foregroundStyle(barColor(bar))
                .cornerRadius(4)
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: zoom.visibleSeconds)
        .chartXAxis {
            AxisMarks(values: .stride(by: zoom == .month ? .month : .day, count: zoom == .day ? 1 : 7)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(minHeight: CGFloat(scheduled.count) * 32 + 60)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            label("Critical", .orange)
            label("Done", .green)
            label("Milestone", .purple)
        }
        .font(.caption)
    }

    private func label(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func barColor(_ bar: ScheduledTask) -> Color {
        if bar.node.checked { return .green.opacity(0.55) }
        if bar.isCritical { return .orange }
        return .accentColor
    }

    private func isMilestone(_ bar: ScheduledTask) -> Bool {
        bar.duration <= 1 && bar.node.title.lowercased().contains("#milestone")
            || labels(of: bar).contains("milestone")
    }

    private func labels(of bar: ScheduledTask) -> [String] {
        tasks.first { $0.id == bar.id }
            .map { TaskEngineLabels.labels(in: $0.text) } ?? []
    }

    // MARK: - Node building

    /// Day 0 = the project's start (or the earliest dated task, or today).
    private var baseDay: String {
        project.projectStart
            ?? tasks.compactMap { $0.startDate ?? $0.dueDate }.min()
            ?? Self.today
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func timelineNodes() -> [TaskNode] {
        tasks.filter { $0.parentId == nil }.map { task in
            TaskNode(
                id: task.id,
                title: task.text,
                checked: task.checked,
                startDay: task.startDate.flatMap { ProjectSchedule.dayOffset($0, from: baseDay) },
                dueDay: task.dueDate.flatMap { ProjectSchedule.dayOffset($0, from: baseDay) },
                blockId: task.blockId,
                dependsOn: task.dependsOn?.split(separator: " ").map(String.init) ?? []
            )
        }
    }

    private func date(for dayOffset: Int) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = formatter.date(from: baseDay) ?? Date()
        return base.addingTimeInterval(TimeInterval(dayOffset) * 86400)
    }
}

/// #labels in task text (the index stores labels per task id, but the
/// timeline only needs a cheap contains check).
enum TaskEngineLabels {
    static func labels(in text: String) -> [String] {
        text.split(separator: " ")
            .filter { $0.hasPrefix("#") }
            .map { String($0.dropFirst()).lowercased() }
    }
}

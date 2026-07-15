import SwiftUI
import WidgetKit

/// "Today's Tasks" widget: reads the snapshot the app publishes to the
/// app-group container on every reindex. Static v1 — tapping opens the
/// app; inline check-off arrives with the interactive pass.
struct TaskSnapshot: Codable {
    struct Item: Codable, Identifiable {
        var id: String
        var text: String
        var priority: Int?
    }

    var updated: Date
    var todayCount: Int
    var overdueCount: Int
    var items: [Item]

    static func load() -> TaskSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "6A2NHN89Q8.com.rchaight.notetaker"
        ) else { return nil }
        let url = container.appendingPathComponent("today-tasks.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TaskSnapshot.self, from: data)
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: TaskSnapshot?
}

struct TodayProvider: TimelineProvider {
    func placeholder(in _: Context) -> TodayEntry {
        TodayEntry(date: .now, snapshot: TaskSnapshot(
            updated: .now, todayCount: 3, overdueCount: 1,
            items: [
                .init(id: "1", text: "Review the design doc", priority: 1),
                .init(id: "2", text: "Email the dean", priority: nil),
            ]
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(
            date: .now,
            snapshot: TaskSnapshot.load() ?? placeholder(in: context).snapshot
        ))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = TodayEntry(date: .now, snapshot: TaskSnapshot.load())
        // The app pokes WidgetCenter on reindex; hourly fallback otherwise.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct TodayTasksWidgetView: View {
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Today", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let snapshot = entry.snapshot, snapshot.overdueCount > 0 {
                    Text("\(snapshot.overdueCount) overdue")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
                ForEach(snapshot.items.prefix(4)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "circle")
                            .font(.caption2)
                            .foregroundStyle(item.priority.map { $0 <= 2 ? Color.red : .accentColor } ?? .accentColor)
                        Text(item.text)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer()
                Text("All clear ✨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

struct TodayTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayTasks", provider: TodayProvider()) { entry in
            TodayTasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Tasks")
        .description("Open tasks due today from your Notetaker vault.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct NotetakerWidgets: WidgetBundle {
    var body: some Widget {
        TodayTasksWidget()
    }
}

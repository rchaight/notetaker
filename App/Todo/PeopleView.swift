import IndexKit
import SwiftUI
import TaskEngine

/// People module: one page per person aggregating everything that touches
/// them — To Discuss (?discuss), Delegated (@person plain tasks), Waiting
/// (?waiting). "Start 1:1" runs the discussion queue Fellow-style and can
/// log the meeting to People/<Name>.md (vault-native, syncs, searchable).
struct PeopleView: View {
    let service: VaultIndexService
    let extrasStore: TaskExtrasStore
    var openNote: (String, Int?) -> Void = { _, _ in }

    @State private var tasks: [TaskRecord] = []
    @State private var selectedPerson: String?
    @State private var runningOneOnOne = false
    @State private var detailTaskId: String?
    @Environment(\.openWindow) private var openWindow

    /// "Unassigned" bucket for ?discuss items with no @person yet.
    static let unassigned = "—"

    private var people: [(person: String, discuss: Int, total: Int)] {
        var buckets: [String: (discuss: Int, total: Int)] = [:]
        for task in tasks {
            let person = task.assignee ?? Self.unassigned
            var entry = buckets[person] ?? (0, 0)
            entry.total += 1
            if task.kind == "discuss" {
                entry.discuss += 1
            }
            buckets[person] = entry
        }
        return buckets
            .map { ($0.key, $0.value.discuss, $0.value.total) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private func tasks(for person: String, kind: String?) -> [TaskRecord] {
        tasks.filter {
            ($0.assignee ?? Self.unassigned) == person && $0.kind == kind
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPerson) {
                ForEach(people, id: \.person) { entry in
                    HStack {
                        Label(
                            entry.person == Self.unassigned ? "Unassigned" : entry.person,
                            systemImage: entry.person == Self.unassigned
                                ? "person.crop.circle.dashed" : "person.crop.circle"
                        )
                        Spacer()
                        if entry.discuss > 0 {
                            Text("\(entry.discuss)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .tag(entry.person)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            .navigationTitle("People")
            .overlay {
                if people.isEmpty {
                    ContentUnavailableView(
                        "No People Yet",
                        systemImage: "person.2",
                        description: Text(
                            "Add @name to a task, or mark talking points with ?discuss:\n- [ ] renewal timeline @Amber ?discuss"
                        )
                    )
                }
            }
        } detail: {
            if let person = selectedPerson {
                personPage(person)
            } else {
                ContentUnavailableView(
                    "Select a Person",
                    systemImage: "person.2",
                    description: Text("To Discuss, Delegated, and Waiting items live here.")
                )
            }
        }
        .task(id: service.tasksVersion) {
            tasks = service.peopleTasks()
        }
        .sheet(isPresented: $runningOneOnOne) {
            if let person = selectedPerson {
                OneOnOneRunView(
                    service: service,
                    person: person,
                    items: tasks(for: person, kind: "discuss")
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { detailTaskId != nil },
                set: {
                    if !$0 {
                        detailTaskId = nil
                    }
                }
            )
        ) {
            if let id = detailTaskId {
                TaskDetailView(service: service, extrasStore: extrasStore, taskId: id)
            }
        }
    }

    private func personPage(_ person: String) -> some View {
        let discuss = tasks(for: person, kind: "discuss")
        let delegated = tasks(for: person, kind: nil)
        let waiting = tasks(for: person, kind: "waiting")
        return List {
            if !discuss.isEmpty {
                Section {
                    ForEach(discuss) { task in
                        taskRow(task, accent: .accentColor)
                    }
                } header: {
                    Label("To Discuss (\(discuss.count))", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if !delegated.isEmpty {
                Section {
                    ForEach(delegated) { task in
                        taskRow(task, accent: .blue)
                    }
                } header: {
                    Label("Delegated (\(delegated.count))", systemImage: "arrow.uturn.right")
                }
            }
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { task in
                        taskRow(task, accent: .orange)
                    }
                } header: {
                    Label("Waiting On (\(waiting.count))", systemImage: "hourglass")
                }
            }
        }
        .navigationTitle(person == Self.unassigned ? "Unassigned" : person)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Start 1:1", systemImage: "play.circle") {
                    runningOneOnOne = true
                }
                .disabled(discuss.isEmpty || person == Self.unassigned)
                .help("Run through the discussion queue and log the meeting")
            }
        }
        .overlay {
            if discuss.isEmpty, delegated.isEmpty, waiting.isEmpty {
                ContentUnavailableView(
                    "All Clear",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing queued for \(person) right now.")
                )
            }
        }
    }

    private func taskRow(_ task: TaskRecord, accent: Color) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await service.toggle(task) }
            } label: {
                Image(systemName: "circle")
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .help("Complete")
            Text(task.text)
                .contentShape(Rectangle())
                .onTapGesture {
                    #if os(macOS)
                        openWindow(id: "task-detail", value: task.id)
                    #else
                        detailTaskId = task.id
                    #endif
                }
            Spacer()
            if let due = task.dueDate {
                Text(due).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                openNote(task.noteId, task.line)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open in note")
        }
        .contextMenu {
            Button("Mark as Task") {
                Task {
                    await service.rewriteTaskLine(task) {
                        TaskLineRewriter.settingKind($0, to: nil)
                    }
                }
            }
            Button("Mark as Waiting") {
                Task {
                    await service.rewriteTaskLine(task) {
                        TaskLineRewriter.settingKind($0, to: "waiting")
                    }
                }
            }
            Button("Mark to Discuss") {
                Task {
                    await service.rewriteTaskLine(task) {
                        TaskLineRewriter.settingKind($0, to: "discuss")
                    }
                }
            }
        }
    }
}

/// Fellow-style meeting run: walk the queue, check what you covered,
/// finish with an optional dated log written into People/<Name>.md.
struct OneOnOneRunView: View {
    let service: VaultIndexService
    let person: String
    let items: [TaskRecord]

    @State private var covered: Set<String> = []
    @State private var logMeeting = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("1:1 with \(person)", systemImage: "person.crop.circle")
                .font(.title2.weight(.semibold))
            Text("\(covered.count) of \(items.count) covered")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(items) { item in
                HStack(spacing: 10) {
                    Button {
                        if covered.contains(item.id) {
                            covered.remove(item.id)
                        } else {
                            covered.insert(item.id)
                        }
                    } label: {
                        Image(systemName: covered.contains(item.id)
                            ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(covered.contains(item.id)
                                ? Color.green : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Text(item.text)
                        .font(.title3)
                        .strikethrough(covered.contains(item.id))
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            Toggle("Log this meeting to People/\(person).md", isOn: $logMeeting)
                .font(.callout)
            HStack {
                Text("Uncovered items stay queued for next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Finish 1:1") {
                    let coveredItems = items.filter { covered.contains($0.id) }
                    let log = logMeeting
                    dismiss()
                    Task {
                        for item in coveredItems {
                            await service.toggle(item)
                        }
                        if log, !coveredItems.isEmpty {
                            await service.appendMeetingLog(
                                person: person,
                                covered: coveredItems.map(\.text)
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(covered.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
    }
}

import IndexKit
import SwiftUI
import TaskEngine

/// Todoist-style task detail: the line-grammar fields edit the markdown
/// source through the existing write engines; description/link/objective
/// live in the private CloudKit database, joined by the task's ^id.
/// Layout: scrollable form + pinned footer (fields were overflow-hidden
/// in the fixed layout, user-reported).
struct TaskDetailView: View {
    let service: VaultIndexService
    let extrasStore: TaskExtrasStore
    let taskId: String
    var openNote: (String, Int?) -> Void = { _, _ in }

    @State private var task: TaskRecord?
    @State private var noteTasks: [TaskRecord] = []
    @State private var titleText = ""
    @State private var dueDate: Date?
    @State private var startDate: Date?
    @State private var priority: Int?
    @State private var assignee = ""
    @State private var isMilestone = false
    @State private var labels: [String] = []
    @State private var extras = TaskExtrasStore.Extras()
    @State private var extrasKey: String?
    @State private var saveState: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let task {
                VStack(spacing: 0) {
                    ScrollView {
                        form(task)
                            .padding(18)
                    }
                    Divider()
                    footer(task)
                }
            } else {
                ContentUnavailableView(
                    "Task Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("It may have been completed, moved, or edited elsewhere.")
                )
            }
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 480, idealHeight: 620)
        .task(id: "\(taskId)-\(service.tasksVersion)") { await load() }
        .onDisappear {
            if let task {
                commitTitle(task)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        let all = service.openTasks() + service.completedTasks()
        task = all.first { $0.id == taskId } ?? service
            .tasks(inNote: taskId.components(separatedBy: "#").first ?? "")
            .first { $0.id == taskId }
        guard let task else { return }
        noteTasks = service.tasks(inNote: task.noteId)
        titleText = task.text
        priority = task.priority
        dueDate = task.dueDate.flatMap(Self.parseISO)
        startDate = task.startDate.flatMap(Self.parseISO)
        labels = service.taskLabels()[task.id] ?? []
        isMilestone = labels.contains("milestone")
        assignee = task.assignee ?? ""
        if let key = task.blockId {
            extrasKey = key
            extras = await extrasStore.extras(for: key)
        }
    }

    // MARK: - Derived status

    private enum Status {
        case done, blocked, ready

        var label: (String, Color) {
            switch self {
            case .done: ("Done", .green)
            case .blocked: ("Blocked", .orange)
            case .ready: ("Open", .blue)
            }
        }
    }

    private func status(_ task: TaskRecord) -> Status {
        if task.checked {
            return .done
        }
        let unfinished = Set(noteTasks.filter { !$0.checked }.compactMap(\.blockId))
        let blocked = (task.dependsOn ?? "")
            .split(separator: " ")
            .contains { unfinished.contains(String($0)) }
        return blocked ? .blocked : .ready
    }

    // MARK: - Form

    private func form(_ task: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    Task {
                        await service.toggle(task)
                        dismiss()
                    }
                } label: {
                    Image(systemName: task.checked ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(task.checked ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(task.checked ? "Reopen" : "Complete")
                TextField("Task", text: $titleText, axis: .vertical)
                    .font(.title3)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(task) }
                    .onChange(of: titleFocused) {
                        if !titleFocused {
                            commitTitle(task)
                        }
                    }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    rowLabel("Status", "circlebadge.2")
                    statusRow(task)
                }
                GridRow {
                    rowLabel("Due", "calendar")
                    datePickerRow(date: $dueDate) { commitDates(task) }
                }
                GridRow {
                    rowLabel("Start", "hourglass")
                    datePickerRow(date: $startDate) { commitDates(task) }
                }
                GridRow {
                    rowLabel("Priority", "flag")
                    Picker("", selection: Binding(
                        get: { priority ?? 0 },
                        set: { priority = $0 == 0 ? nil : $0; commitPriority(task) }
                    )) {
                        Text("None").tag(0)
                        ForEach(1 ... 4, id: \.self) { level in
                            Text("P\(level)").tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                GridRow {
                    rowLabel("Assignee", "person")
                    TextField("@name", text: $assignee)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit { commitAssignee(task) }
                }
                GridRow {
                    rowLabel("Milestone", "diamond")
                    Toggle("", isOn: Binding(
                        get: { isMilestone },
                        set: { isMilestone = $0; commitMilestone(task) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                GridRow {
                    rowLabel("Blocked by", "hand.raised")
                    dependencyRow(task)
                }
                if let recurrence = task.recurrence {
                    GridRow {
                        rowLabel("Repeats", "repeat")
                        Text(recurrence).font(.callout)
                    }
                }
                GridRow {
                    rowLabel("Project", "calendar.day.timeline.left")
                    projectMenu(task)
                }
                GridRow {
                    rowLabel("Note", "note.text")
                    Button {
                        openNote(task.noteId, task.line)
                        dismiss()
                    } label: {
                        Text(noteName(task.noteId))
                            .foregroundStyle(Color.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                rowLabel("Objective", "target")
                TextField("What does done look like?", text: $extras.objective)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    rowLabel("Description", "text.alignleft")
                    Spacer()
                    if case let .unavailable(message) = extrasStore.state {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    } else if let saveState {
                        Text(saveState).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextEditor(text: $extras.description)
                    .font(.body)
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                TextField("Link (https://…)", text: $extras.url)
                    .textFieldStyle(.roundedBorder)
                Text(
                    "Objective, description & link sync via your private iCloud database. Everything else lives in the note's markdown line."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func statusRow(_ task: TaskRecord) -> some View {
        let (text, color) = status(task).label
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout)
            if isMilestone {
                Text("· Milestone")
                    .font(.callout)
                    .foregroundStyle(.purple)
            }
        }
    }

    private func footer(_ task: TaskRecord) -> some View {
        HStack {
            Spacer()
            Button("Save Details") { Task { await saveExtras(task) } }
                .buttonStyle(.borderedProminent)
                .disabled(extrasStore.state == .loading)
        }
        .padding(12)
        .background(.bar)
    }

    private func rowLabel(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
            .font(.callout)
    }

    private func datePickerRow(
        date: Binding<Date?>, commit: @escaping () -> Void
    ) -> some View {
        HStack {
            DatePicker(
                "",
                selection: Binding(
                    get: { date.wrappedValue ?? Date() },
                    set: { date.wrappedValue = $0; commit() }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            .opacity(date.wrappedValue == nil ? 0.4 : 1)
            if date.wrappedValue != nil {
                Button("Clear") {
                    date.wrappedValue = nil
                    commit()
                }
                .controlSize(.small)
            } else {
                Text("None").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func dependencyRow(_ task: TaskRecord) -> some View {
        HStack(spacing: 8) {
            let current = (task.dependsOn ?? "").split(separator: " ").map(String.init)
            if !current.isEmpty {
                Text(current.map { "^" + $0 }.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Menu("Add…") {
                ForEach(noteTasks.filter { $0.id != task.id && !$0.checked }) { other in
                    Button(other.text) {
                        Task { await service.addDependency(dependent: task, target: other) }
                    }
                }
            }
            .fixedSize()
            .disabled(noteTasks.count < 2)
        }
    }

    private func projectMenu(_ task: TaskRecord) -> some View {
        Menu {
            ForEach(service.projects().filter { $0.id != task.noteId }, id: \.id) { project in
                Button(project.title) {
                    Task {
                        if await service.moveTask(task, toNote: project.id) {
                            dismiss()
                        }
                    }
                }
            }
            if task.noteId != "Inbox.md" {
                Divider()
                Button("Inbox") {
                    Task {
                        if await service.moveTask(task, toNote: "Inbox.md") {
                            dismiss()
                        }
                    }
                }
            }
        } label: {
            Text(service.projects().first { $0.id == task.noteId }?.title ?? "Move to…")
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    // MARK: - Commits (each through the grammar-safe write engines)

    private func commitTitle(_ task: TaskRecord) {
        let newTitle = titleText.trimmingCharacters(in: .whitespaces)
        guard !newTitle.isEmpty, newTitle != task.text else { return }
        Task {
            await service.rewriteTaskLine(task) { line in
                TaskLineRewriter.replacingText(line, with: newTitle)
            }
        }
    }

    private func commitDates(_ task: TaskRecord) {
        let due = dueDate.map(Self.formatISO)
        let start: String?? = .some(startDate.map(Self.formatISO))
        Task { await service.reschedule(task, due: due, start: start) }
    }

    private func commitPriority(_ task: TaskRecord) {
        let level = priority
        Task { await service.setPriority(task, priority: level) }
    }

    private func commitAssignee(_ task: TaskRecord) {
        let name = assignee
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
        Task {
            await service.rewriteTaskLine(task) { line in
                TaskLineRewriter.settingAssignee(line, to: name.isEmpty ? nil : name)
            }
        }
    }

    private func commitMilestone(_ task: TaskRecord) {
        let on = isMilestone
        Task {
            await service.rewriteTaskLine(task) { line in
                on
                    ? TaskLineRewriter.addingLabel(line, label: "milestone")
                    : TaskLineRewriter.removingLabel(line, label: "milestone")
            }
        }
    }

    private func saveExtras(_ task: TaskRecord) async {
        commitTitle(task)
        commitAssignee(task)
        saveState = "Saving…"
        var key = extrasKey
        if key == nil {
            key = await service.ensureStableId(task)
            extrasKey = key
        }
        guard let key else {
            saveState = "Couldn't assign an id"
            return
        }
        saveState = await extrasStore.save(extras, for: key) ? "Saved ✓" : nil
        try? await Task.sleep(for: .seconds(2))
        saveState = nil
    }

    private func noteName(_ noteId: String) -> String {
        URL(fileURLWithPath: noteId).deletingPathExtension().lastPathComponent
    }

    static func parseISO(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    static func formatISO(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

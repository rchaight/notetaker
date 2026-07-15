import IndexKit
import SwiftUI
import TaskEngine

/// Todoist-style task detail: the line-grammar fields edit the markdown
/// source through the existing write engines; the description and link
/// live in the private CloudKit database, joined by the task's ^id.
struct TaskDetailView: View {
    let service: VaultIndexService
    let extrasStore: TaskExtrasStore
    let taskId: String
    var openNote: (String, Int?) -> Void = { _, _ in }

    @State private var task: TaskRecord?
    @State private var titleText = ""
    @State private var dueDate: Date?
    @State private var priority: Int?
    @State private var extras = TaskExtrasStore.Extras()
    @State private var extrasKey: String?
    @State private var saveState: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let task {
                form(task)
            } else {
                ContentUnavailableView(
                    "Task Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("It may have been completed or edited elsewhere.")
                )
            }
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420)
        .task(id: "\(taskId)-\(service.tasksVersion)") { await load() }
        .onDisappear {
            if let task {
                commitTitle(task)
            }
        }
    }

    private func load() async {
        let all = service.openTasks() + service.completedTasks()
        task = all.first { $0.id == taskId }
        guard let task else { return }
        titleText = task.text
        priority = task.priority
        dueDate = task.dueDate.flatMap(Self.parseISO)
        if let key = task.blockId {
            extrasKey = key
            extras = await extrasStore.extras(for: key)
        }
    }

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

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Label("Due", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                    HStack {
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { dueDate ?? Date() },
                                set: { dueDate = $0; commitDue(task) }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .opacity(dueDate == nil ? 0.4 : 1)
                        if dueDate != nil {
                            Button("Clear") {
                                dueDate = nil
                                commitDue(task)
                            }
                            .controlSize(.small)
                        } else {
                            Text("No due date").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Label("Priority", systemImage: "flag")
                        .foregroundStyle(.secondary)
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
                if let recurrence = task.recurrence {
                    GridRow {
                        Label("Repeats", systemImage: "repeat")
                            .foregroundStyle(.secondary)
                        Text(recurrence).font(.callout)
                    }
                }
                GridRow {
                    Label("Project", systemImage: "calendar.day.timeline.left")
                        .foregroundStyle(.secondary)
                    Menu {
                        ForEach(
                            service.projects().filter { $0.id != task.noteId }, id: \.id
                        ) { project in
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
                        Text(
                            service.projects().first { $0.id == task.noteId }?.title
                                ?? "Move to…"
                        )
                    }
                    .menuIndicator(.visible)
                    .fixedSize()
                }
                GridRow {
                    Label("Note", systemImage: "note.text")
                        .foregroundStyle(.secondary)
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
                HStack {
                    Label("Description", systemImage: "text.alignleft")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if case let .unavailable(message) = extrasStore.state {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    } else if let saveState {
                        Text(saveState).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextEditor(text: $extras.description)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                TextField("Link (https://…)", text: $extras.url)
                    .textFieldStyle(.roundedBorder)
                Text(
                    "Description and link sync via your private iCloud database, joined to this task by a hidden id. Everything else lives in the note's markdown line."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Save Details") { Task { await saveExtras(task) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(extrasStore.state == .loading)
            }
        }
        .padding(18)
    }

    private func commitTitle(_ task: TaskRecord) {
        let newTitle = titleText.trimmingCharacters(in: .whitespaces)
        guard !newTitle.isEmpty, newTitle != task.text else { return }
        Task {
            await service.rewriteTaskLine(task) { line in
                TaskLineRewriter.replacingText(line, with: newTitle)
            }
        }
    }

    private func commitDue(_ task: TaskRecord) {
        let iso = dueDate.map(Self.formatISO)
        Task { await service.reschedule(task, due: iso) }
    }

    private func commitPriority(_ task: TaskRecord) {
        let level = priority
        Task { await service.setPriority(task, priority: level) }
    }

    private func saveExtras(_ task: TaskRecord) async {
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

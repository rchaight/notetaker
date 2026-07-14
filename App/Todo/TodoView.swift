import IndexKit
import SwiftUI
import TaskEngine

/// The master To-Do tab: every inline `- [ ]` across the vault, live,
/// grouped into Overdue / Today / Upcoming / Inbox. Checking a row edits
/// the exact source line in the note.
struct TodoView: View {
    let service: VaultIndexService
    @State private var grouped: [SmartBucket: [TaskRecord]] = [:]
    @State private var subtaskProgress: [String: (done: Int, total: Int)] = [:]
    @State private var showingQuickAdd = false
    @State private var quickAddText = ""
    /// Things-style calm completion: rows strike + fade for a beat before
    /// the write removes them from the list.
    @State private var completingIds: Set<String> = []
    @State private var filterText = ""
    @State private var viewMode: ViewMode = .list

    enum ViewMode: String, CaseIterable {
        case list = "List"
        case board = "Board"
        case agenda = "Agenda"
        case matrix = "Matrix"
    }

    @AppStorage("savedTaskFilters") private var savedFiltersJSON = "[]"

    private var savedFilters: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(savedFiltersJSON.utf8))) ?? []
    }

    private func setSavedFilters(_ filters: [String]) {
        savedFiltersJSON = (try? String(data: JSONEncoder().encode(filters), encoding: .utf8)) ?? "[]"
    }

    private static let sections: [(SmartBucket, String, String)] = [
        (.overdue, "Overdue", "exclamationmark.circle"),
        (.today, "Today", "star"),
        (.upcoming, "Upcoming", "calendar"),
        (.inbox, "Inbox", "tray"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 6)
                filterBar
                currentView
            }
            .navigationTitle("To-Do")
            .toolbar {
                ToolbarItem {
                    Button("New Task", systemImage: "plus") {
                        showingQuickAdd = true
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Quick Add (⇧⌘N) — e.g. \"email dean tomorrow p1 #admin\"")
                }
            }
        }
        .sheet(isPresented: $showingQuickAdd) {
            quickAddSheet
        }
        .task {
            await service.start()
            refresh()
        }
        .onChange(of: service.tasksVersion) {
            refresh()
        }
        .onChange(of: filterText) {
            refresh()
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("Filter — p1  due:today|overdue|week|none  #label  words", text: $filterText)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(savedFilters, id: \.self) { saved in
                    Button(saved) { filterText = saved }
                }
                if !savedFilters.isEmpty {
                    Divider()
                }
                if !filterText.trimmingCharacters(in: .whitespaces).isEmpty,
                   !savedFilters.contains(filterText) {
                    Button("Save Current Filter", systemImage: "plus.circle") {
                        setSavedFilters(savedFilters + [filterText])
                    }
                }
                if savedFilters.contains(filterText) {
                    Button("Delete Saved Filter", systemImage: "trash", role: .destructive) {
                        setSavedFilters(savedFilters.filter { $0 != filterText })
                    }
                }
                if !filterText.isEmpty {
                    Button("Clear Filter", systemImage: "xmark.circle") { filterText = "" }
                }
            } label: {
                Image(systemName: filterText.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
            }
            .menuIndicator(.hidden)
            .help("Saved filters")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var allFilteredTasks: [TaskRecord] {
        grouped.values.flatMap(\.self)
    }

    @ViewBuilder private var currentView: some View {
        switch viewMode {
        case .list:
            taskList
        case .board:
            TaskBoardView(grouped: grouped, subtaskProgress: subtaskProgress) { task in
                Task { await service.toggle(task) }
            }
        case .agenda:
            TaskAgendaView(tasks: allFilteredTasks) { task in
                Task { await service.toggle(task) }
            }
        case .matrix:
            TaskMatrixView(tasks: allFilteredTasks) { task in
                Task { await service.toggle(task) }
            }
        }
    }

    private var taskList: some View {
        List {
            ForEach(Self.sections, id: \.0) { bucket, title, icon in
                if let tasks = grouped[bucket], !tasks.isEmpty {
                    Section {
                        ForEach(tasks) { task in
                            row(task)
                        }
                    } header: {
                        Label(title, systemImage: icon)
                            .foregroundStyle(bucket == .overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
        .overlay {
            if grouped.values.allSatisfy(\.isEmpty) || grouped.isEmpty {
                ContentUnavailableView(
                    "No Open Tasks",
                    systemImage: "checklist",
                    description: Text("Write - [ ] anywhere in a note and it appears here.")
                )
            }
        }
    }

    private var quickAddSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Add")
                .font(.headline)
            TextField("email dean tomorrow p1 #admin", text: $quickAddText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitQuickAdd() }
            Text("Natural dates work (tomorrow, friday, jul 20) — or tokens: >date  !p1–p4  #label  &every 3 days")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingQuickAdd = false
                    quickAddText = ""
                }
                Button("Add Task") { submitQuickAdd() }
                    .buttonStyle(.borderedProminent)
                    .disabled(quickAddText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .presentationDetents([.height(200)])
    }

    private func submitQuickAdd() {
        let input = quickAddText
        showingQuickAdd = false
        quickAddText = ""
        Task { await service.quickAdd(input) }
    }

    /// Strike + fade in place (~0.4s), then write the toggle; the reindex
    /// removes the row with a standard list animation.
    private func completeWithFade(_ task: TaskRecord) {
        guard !completingIds.contains(task.id) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            _ = completingIds.insert(task.id)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await service.toggle(task)
            completingIds.remove(task.id)
        }
    }

    private func refresh() {
        let filter = TaskFilter.parse(filterText)
        let labels = filter.isEmpty ? [:] : service.taskLabels()
        let tasks = service.openTasks().filter { task in
            filter.isEmpty || filter.matches(
                text: task.text, noteId: task.noteId, dueDate: task.dueDate,
                priority: task.priority, labels: labels[task.id] ?? []
            )
        }
        grouped = Dictionary(grouping: tasks) {
            SmartBuckets.bucket(dueDate: $0.dueDate, startDate: $0.startDate)
        }
        subtaskProgress = service.subtaskProgress()
    }

    private func row(_ task: TaskRecord) -> some View {
        let completing = completingIds.contains(task.id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                completeWithFade(task)
            } label: {
                Image(systemName: completing ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(completing ? Color.secondary : priorityColor(task.priority))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete task")
            .disabled(completing)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.text)
                    .strikethrough(completing)
                HStack(spacing: 8) {
                    if let due = task.dueDate {
                        Label(due, systemImage: "calendar")
                    }
                    if let start = task.startDate {
                        Label("from \(start)", systemImage: "hourglass")
                    }
                    if let priority = task.priority {
                        Text("P\(priority)")
                            .fontWeight(.semibold)
                            .foregroundStyle(priorityColor(priority))
                    }
                    if let progress = subtaskProgress[task.id] {
                        Label("\(progress.done)/\(progress.total)", systemImage: "checklist")
                            .foregroundStyle(progress.done == progress.total ? .green : .secondary)
                    }
                    Text(noteName(task.noteId))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .opacity(completing ? 0.45 : 1)
    }

    private func noteName(_ noteId: String) -> String {
        URL(fileURLWithPath: noteId).deletingPathExtension().lastPathComponent
    }

    private func priorityColor(_ priority: Int?) -> Color {
        switch priority {
        case 1: .red
        case 2: .orange
        case 3: .blue
        default: .secondary
        }
    }
}

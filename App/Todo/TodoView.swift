import IndexKit
import SwiftUI
import TaskEngine

/// The master To-Do tab: every inline `- [ ]` across the vault, live,
/// grouped into Overdue / Today / Upcoming / Inbox. Checking a row edits
/// the exact source line in the note.
struct TodoView: View {
    let service: VaultIndexService
    /// Ribbon signal: each increment opens the Quick Add sheet.
    var quickAddSignal = 0
    /// Jump to the task's source note (noteId, line) — wired by AppShell.
    var openNote: (String, Int?) -> Void = { _, _ in }
    @State private var grouped: [SmartBucket: [TaskRecord]] = [:]
    @State private var subtaskProgress: [String: (done: Int, total: Int)] = [:]
    @State private var showingQuickAdd = false
    @State private var quickAddText = ""
    /// Things-style calm completion: rows strike + fade for a beat before
    /// the write removes them from the list.
    @State private var completingIds: Set<String> = []
    @State private var taskLabels: [String: [String]] = [:]
    @State private var selectedTaskIds: Set<String> = []
    @AppStorage("todoDensity") private var densityRaw = "comfortable"
    @AppStorage("showStreaks") private var showStreaks = false

    private enum Density: String, CaseIterable {
        case compact, comfortable, relaxed

        var title: String {
            rawValue.capitalized
        }

        var rowPadding: CGFloat {
            switch self {
            case .compact: 0
            case .comfortable: 4
            case .relaxed: 9
            }
        }

        var textFont: Font {
            self == .compact ? .callout : .body
        }

        var showsMetaLine: Bool {
            self != .compact
        }
    }

    private var density: Density {
        Density(rawValue: densityRaw) ?? .comfortable
    }

    @State private var filterText = ""
    @AppStorage("todoViewMode") private var viewModeRaw = ViewMode.list.rawValue
    private var viewMode: ViewMode {
        ViewMode(rawValue: viewModeRaw) ?? .list
    }

    enum ViewMode: String, CaseIterable {
        case list = "List"
        case board = "Board"
        case agenda = "Agenda"
        case matrix = "Matrix"
        case log = "Log"
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
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
                .navigationTitle("To-Do")
        } detail: {
            currentView
                .navigationTitle("To-Do")
                .toolbar {
                    ToolbarItem {
                        if showStreaks {
                            streakChip
                        }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("New Task", systemImage: "square.and.pencil") {
                            showingQuickAdd = true
                        }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        .help("Quick Add (⇧⌘N) — e.g. \"email dean tomorrow p1 #admin\"")
                        Button("Agenda", systemImage: "calendar") {
                            viewModeRaw = ViewMode.agenda.rawValue
                        }
                        .help("Agenda view (by date)")
                        Button("Logbook", systemImage: "checkmark.circle") {
                            viewModeRaw = ViewMode.log.rawValue
                        }
                        .help("Completed tasks by day")
                    }
                }
        }
        .sheet(isPresented: $showingQuickAdd) {
            quickAddSheet
        }
        .onChange(of: quickAddSignal) {
            showingQuickAdd = true
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

    /// Mirrors the Notes sidebar: filter field on top, compact icon strip
    /// (positions match Notes — new to-do where new note sits), then lists.
    private var sidebar: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.top, 2)
            sidebarActionBar
            sidebarLists
        }
    }

    private var sidebarActionBar: some View {
        HStack(spacing: 4) {
            actionIcon("square.and.pencil", "New to-do (⇧⌘N)") {
                showingQuickAdd = true
            }
            actionIcon("text.badge.plus", "Save current filter") {
                let trimmed = filterText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !savedFilters.contains(trimmed) {
                    setSavedFilters(savedFilters + [trimmed])
                }
            }
            actionIcon("checkmark.circle", "Open the Logbook") {
                viewModeRaw = ViewMode.log.rawValue
            }
            Spacer()
            Menu {
                Toggle("Show Streaks", isOn: $showStreaks)
                Picker("Density", selection: $densityRaw) {
                    ForEach(Density.allCases, id: \.rawValue) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            } label: {
                Image(systemName: "rectangle.arrowtriangle.2.inward")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Density & streaks")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func actionIcon(
        _ icon: String, _ help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var sidebarLists: some View {
        List {
            Section("Views") {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: Self.modeIcon(mode))
                        .contentShape(Rectangle())
                        .listRowBackground(
                            viewMode == mode ? Color.accentColor.opacity(0.18) : Color.clear
                        )
                        .onTapGesture { viewModeRaw = mode.rawValue }
                }
            }
            if !savedFilters.isEmpty {
                Section("Saved Filters") {
                    ForEach(savedFilters, id: \.self) { saved in
                        Label(saved, systemImage: "line.3.horizontal.decrease")
                            .contentShape(Rectangle())
                            .listRowBackground(
                                filterText == saved ? Color.accentColor.opacity(0.18) : Color.clear
                            )
                            .onTapGesture {
                                filterText = filterText == saved ? "" : saved
                            }
                    }
                }
            }
        }
    }

    private static func modeIcon(_ mode: ViewMode) -> String {
        switch mode {
        case .list: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .agenda: "calendar"
        case .matrix: "square.grid.2x2"
        case .log: "checkmark.circle"
        }
    }

    @ViewBuilder private var currentView: some View {
        switch viewMode {
        case .list:
            taskList
        case .board:
            TaskBoardView(
                grouped: grouped,
                subtaskProgress: subtaskProgress,
                onComplete: { task in Task { await service.toggle(task) } },
                onReschedule: { task, due in Task { await service.reschedule(task, due: due) } }
            )
        case .agenda:
            TaskAgendaView(
                tasks: allFilteredTasks,
                onComplete: { task in Task { await service.toggle(task) } },
                onReschedule: { task, due in Task { await service.reschedule(task, due: due) } }
            )
        case .matrix:
            TaskMatrixView(tasks: allFilteredTasks) { task in
                Task { await service.toggle(task) }
            }
        case .log:
            logbook
        }
    }

    private var taskList: some View {
        List(selection: $selectedTaskIds) {
            ForEach(Self.sections, id: \.0) { bucket, title, icon in
                if let tasks = grouped[bucket], !tasks.isEmpty {
                    Section {
                        ForEach(tasks) { task in
                            row(task).tag(task.id)
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
        .safeAreaInset(edge: .bottom) {
            if selectedTaskIds.count > 1 {
                batchBar
            }
        }
    }

    /// Superlist-style bulk actions over the ⌘-click selection.
    private var batchBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedTaskIds.count) selected")
                .font(.callout.weight(.medium))
            Button("Complete", systemImage: "checkmark.circle") {
                batch { await service.toggle($0) }
            }
            Menu("Priority") {
                ForEach(1 ... 4, id: \.self) { level in
                    Button("P\(level)") {
                        batch { await service.setPriority($0, priority: level) }
                    }
                }
                Button("Clear") { batch { await service.setPriority($0, priority: nil) } }
            }
            Menu("Due") {
                Button("Today") {
                    batch { await service.reschedule($0, due: Self.todayISO()) }
                }
                Button("Tomorrow") {
                    batch { await service.reschedule($0, due: Self.tomorrowISO()) }
                }
                Button("Clear") {
                    batch { await service.reschedule($0, due: nil) }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                batch { await service.deleteTask($0) }
            }
            Spacer()
            Button("Done") { selectedTaskIds = [] }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func batch(_ operation: @escaping (TaskRecord) async -> Void) {
        let targets = allFilteredTasks.filter { selectedTaskIds.contains($0.id) }
        selectedTaskIds = []
        Task {
            for task in targets {
                await operation(task)
            }
        }
    }

    /// Things-style Logbook: completed tasks grouped by day, newest first.
    /// Unchecking here reopens the task (and strips its ✅ token).
    private var logbook: some View {
        let completed = service.completedTasks()
        let byDay = Dictionary(grouping: completed) { $0.completedDay ?? "Unknown" }
            .sorted { $0.key > $1.key }
        return List {
            ForEach(byDay, id: \.0) { day, tasks in
                Section(day) {
                    ForEach(tasks) { task in
                        HStack(spacing: 10) {
                            Button {
                                Task { await service.toggle(task) }
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                            .help("Reopen")
                            Text(task.text)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(noteName(task.noteId))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .overlay {
            if completed.isEmpty {
                ContentUnavailableView(
                    "Nothing Logged Yet",
                    systemImage: "checkmark.circle",
                    description: Text("Completed tasks appear here, grouped by day.")
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

    private var streakChip: some View {
        let stats = Streaks.compute(
            completedDays: service.completedTasks().compactMap(\.completedDay)
        )
        return Text("\(stats.doneToday) done today · \(stats.streakDays)-day streak")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func refresh() {
        let filter = TaskFilter.parse(filterText)
        let labels = service.taskLabels()
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
        taskLabels = service.taskLabels()
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
            .help("Complete task")
            .disabled(completing)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.text)
                    .font(density.textFont)
                    .strikethrough(completing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { openNote(task.noteId, task.line) }
                if density.showsMetaLine {
                    metaLine(task)
                }
            }
        }
        .padding(.vertical, density.rowPadding)
        .opacity(completing ? 0.45 : 1)
        .contextMenu {
            Button("Open in Note", systemImage: "arrow.up.right.square") {
                openNote(task.noteId, task.line)
            }
            Button("Snooze to Tomorrow", systemImage: "moon.zzz") {
                Task { await service.reschedule(task, due: Self.tomorrowISO()) }
            }
            Button("Delete Task", systemImage: "trash", role: .destructive) {
                Task { await service.deleteTask(task) }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                completeWithFade(task)
            } label: {
                Label("Complete", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await service.deleteTask(task) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task { await service.reschedule(task, due: Self.tomorrowISO()) }
            } label: {
                Label("Tomorrow", systemImage: "moon.zzz")
            }
            .tint(.orange)
        }
    }

    static func todayISO(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func tomorrowISO(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return formatter.string(from: tomorrow)
    }

    private func metaLine(_ task: TaskRecord) -> some View {
        HStack(spacing: 8) {
            if let due = task.dueDate {
                Label(due, systemImage: "calendar")
            }
            if let start = task.startDate {
                Label("from \(start)", systemImage: "hourglass")
            }
            PriorityChip(priority: task.priority)
            LabelChips(labels: taskLabels[task.id] ?? [])
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

import IndexKit
import ProjectKit
import SwiftUI

/// Projects are notes with `project: true` frontmatter; this tab is a view
/// over them — status, dates, and auto-% complete from their inline todos.
struct ProjectsView: View {
    let service: VaultIndexService
    var extrasStore = TaskExtrasStore()
    /// Ribbon signal: each increment opens the New Project prompt.
    var newProjectSignal = 0
    @State private var projects: [NoteRecord] = []
    @State private var progress: [String: (done: Int, total: Int)] = [:]
    @State private var selectedId: String?
    @State private var showingNewProject = false
    @State private var newProjectName = ""

    var body: some View {
        NavigationSplitView {
            List(projects, id: \.id, selection: $selectedId) { project in
                projectRow(project)
                    .tag(project.id)
            }
            .navigationTitle("Projects")
            .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Project", systemImage: "square.and.pencil") {
                        newProjectName = ""
                        showingNewProject = true
                    }
                    .help("Create a project note (a regular .md note with project frontmatter)")
                }
            }
            .onChange(of: newProjectSignal) {
                newProjectName = ""
                showingNewProject = true
            }
            .alert("New Project", isPresented: $showingNewProject) {
                TextField("Project name", text: $newProjectName)
                Button("Create") {
                    Task {
                        if let id = await service.createProject(named: newProjectName) {
                            projects = service.projects()
                            selectedId = id
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .overlay {
                if projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects Yet",
                        systemImage: "calendar.day.timeline.left",
                        description: Text(
                            "Create one with the + button, right-click a note and choose Make Project, or add `project: true` to a note's frontmatter."
                        )
                    )
                }
            }
        } detail: {
            if let project = projects.first(where: { $0.id == selectedId }) {
                ProjectDetailView(
                    service: service, extrasStore: extrasStore, project: project
                )
            } else {
                ContentUnavailableView(
                    "Select a Project", systemImage: "calendar.day.timeline.left", description: nil
                )
            }
        }
        .task(id: service.tasksVersion) {
            projects = service.projects()
            progress = service.noteTaskProgress()
        }
    }

    private func projectRow(_ project: NoteRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(project.title)
                    .fontWeight(.medium)
                Spacer()
                statusBadge(project.projectStatus)
            }
            let stats = progress[project.id] ?? (0, 0)
            ProgressView(value: ProjectProgress.fraction(done: stats.done, total: stats.total))
                .tint(stats.done == stats.total && stats.total > 0 ? .green : .accentColor)
            HStack {
                Text("\(stats.done)/\(stats.total) tasks")
                Spacer()
                if let due = project.projectDue {
                    Text("due \(due)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func statusBadge(_ status: String?) -> some View {
        if let status {
            Text(status)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(statusColor(status).opacity(0.18), in: Capsule())
                .foregroundStyle(statusColor(status))
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch ProjectMetadata.Status(rawValue: status) {
        case .active: .blue
        case .done: .green
        case .onHold: .orange
        case .planned, nil: .secondary
        }
    }
}

/// Read-only project detail: dates + the note's full task list in file
/// order. Checking off a task writes to the source line, same engine as
/// everywhere else; the timeline view arrives with M7a.
struct ProjectDetailView: View {
    let service: VaultIndexService
    var extrasStore = TaskExtrasStore()
    let project: NoteRecord
    @State private var tasks: [TaskRecord] = []
    @State private var mode: Mode = .tasks
    @State private var newTaskText = ""
    @State private var detailTaskId: String?
    @Environment(\.openWindow) private var openWindow

    enum Mode: String, CaseIterable, Identifiable {
        case tasks = "Tasks"
        case timeline = "Timeline"
        case board = "Board"
        var id: String {
            rawValue
        }
    }

    var body: some View {
        Group {
            switch mode {
            case .tasks: taskList
            case .timeline:
                ScrollView {
                    ProjectTimelineView(service: service, project: project, tasks: tasks)
                }
            case .board:
                ProjectBoardView(service: service, tasks: tasks)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(project.title)
        .task(id: "\(project.id)-\(service.tasksVersion)") {
            tasks = service.tasks(inNote: project.id)
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

    /// Same detail surface as the To-Do tab: window on macOS, sheet on iOS.
    private func openDetail(_ task: TaskRecord) {
        #if os(macOS)
            openWindow(id: "task-detail", value: task.id)
        #else
            detailTaskId = task.id
        #endif
    }

    private var taskList: some View {
        List {
            Section {
                LabeledContent("Status", value: project.projectStatus ?? "—")
                LabeledContent("Start", value: project.projectStart ?? "—")
                LabeledContent("Due", value: project.projectDue ?? "—")
            }
            Section("Tasks") {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                    TextField(
                        "Add a task — \"design review friday p2 #api\"",
                        text: $newTaskText
                    )
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let input = newTaskText.trimmingCharacters(in: .whitespaces)
                        guard !input.isEmpty else { return }
                        newTaskText = ""
                        Task { _ = await service.addTask(to: project.id, input: input) }
                    }
                }
                ForEach(tasks) { task in
                    HStack(spacing: 8) {
                        Button {
                            Task { await service.toggle(task) }
                        } label: {
                            Image(systemName: task.checked ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.checked ? Color.secondary : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(task.checked ? "Reopen task" : "Complete task")
                        Text(task.text)
                            .strikethrough(task.checked)
                            .foregroundStyle(task.checked ? .secondary : .primary)
                            .contentShape(Rectangle())
                            .onTapGesture { openDetail(task) }
                            .help("Open task details")
                        Spacer()
                        if task.dependsOn != nil {
                            Image(systemName: "link")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Has dependencies")
                        }
                        if let due = task.dueDate {
                            Text(due)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Menu("Blocked By") {
                            ForEach(tasks.filter { $0.id != task.id }) { other in
                                Button(other.text) {
                                    Task {
                                        await service.addDependency(dependent: task, target: other)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

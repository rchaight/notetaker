import AIKit
import IndexKit
import SwiftUI

/// Dedicated Tags tab: browse, filter, and curate every tag in the vault.
/// Left: searchable tag list + merge suggestions. Right: the notes carrying
/// the selected tag (open in the Notes tab with one click).
struct TagsView: View {
    let service: VaultIndexService
    let model: NotesModel
    /// Opens a note in the Notes tab (wired by AppShell).
    var openNote: (String) -> Void = { _ in }

    var extrasStore = TaskExtrasStore()
    @State private var tagStore = TagExtrasStore()
    @State private var allTags: [(tag: String, count: Int)] = []
    @State private var selectedTags: Set<String> = []
    @State private var groupSuggestions: [TagGroup] = []
    @State private var tagDescription = ""
    @State private var descriptionTag: String?
    @State private var detailTaskId: String?
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    private var selectedTag: String? {
        selectedTags.count == 1 ? selectedTags.first : nil
    }

    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var mergeSuggestions: [TagMerge] = []
    @State private var suggesting = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
                .navigationTitle("Tags")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            suggesting = true
                            Task {
                                mergeSuggestions = await service.suggestTagMerges()
                                suggesting = false
                            }
                        } label: {
                            Label("Suggest Merges", systemImage: "wand.and.stars")
                        }
                        .help("Find duplicate-ish tags to fold together (heuristics + local Ollama)")
                        .disabled(suggesting)
                    }
                }
        } detail: {
            detail
        }
        .task(id: service.tasksVersion) {
            allTags = service.noteTags()
        }
        .alert(
            "Rename Tag",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: {
                    if !$0 {
                        renameTarget = nil
                    }
                }
            )
        ) {
            TextField("New tag name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    let newName = renameText
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "#", with: "")
                    Task {
                        await service.renameTag(from: target, to: newName)
                        await tagStore.move(from: target, to: newName)
                        allTags = service.noteTags()
                        if selectedTags.contains(target) {
                            selectedTags.remove(target)
                            selectedTags.insert(newName)
                        }
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Rewrites #\(renameTarget ?? "") in every note that carries it.")
        }
    }

    private var filteredTags: [(tag: String, count: Int)] {
        allTags
            .filter { search.isEmpty || $0.tag.localizedCaseInsensitiveContains(search) }
            .sorted { $0.count > $1.count }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter tags…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    suggesting = true
                    Task {
                        async let merges = service.suggestTagMerges()
                        async let groups = service.suggestTagGroups()
                        mergeSuggestions = await merges
                        groupSuggestions = await groups
                        suggesting = false
                    }
                } label: {
                    if suggesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                }
                .help("Suggest tag merges (heuristics + local Ollama when configured)")
                .disabled(suggesting)
            }
            .padding(10)
            if !mergeSuggestions.isEmpty || !groupSuggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !mergeSuggestions.isEmpty {
                            suggestionList
                        }
                        if !groupSuggestions.isEmpty {
                            groupList
                        }
                    }
                }
                .frame(maxHeight: 220)
                Divider()
            }
            if selectedTags.count > 1 {
                bulkBar
                Divider()
            }
            List(selection: $selectedTags) {
                ForEach(filteredTags, id: \.tag) { entry in
                    HStack {
                        Label(entry.tag, systemImage: "number")
                        Spacer()
                        Text("\(entry.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.tag)
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") {
                            renameText = entry.tag
                            renameTarget = entry.tag
                        }
                        Menu("Merge Into") {
                            ForEach(
                                allTags.filter { $0.tag != entry.tag }.map(\.tag).sorted(),
                                id: \.self
                            ) { other in
                                Button("#" + other) {
                                    Task {
                                        await service.renameTag(from: entry.tag, to: other)
                                        await tagStore.move(from: entry.tag, to: other)
                                        allTags = service.noteTags()
                                    }
                                }
                            }
                        }
                        Button(
                            "Remove Tag Everywhere", systemImage: "trash", role: .destructive
                        ) {
                            Task {
                                await service.deleteTag(entry.tag)
                                allTags = service.noteTags()
                                selectedTags.remove(entry.tag)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if allTags.isEmpty {
                    ContentUnavailableView(
                        "No Tags Yet",
                        systemImage: "number",
                        description: Text("Write #topic in any note's text and it appears here.")
                    )
                }
            }
        }
    }

    /// Bulk actions over the multi-selection.
    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedTags.count) tags")
                .font(.callout.weight(.medium))
            Menu("Merge Into") {
                ForEach(allTags.map(\.tag).sorted(), id: \.self) { target in
                    Button("#" + target) {
                        let sources = selectedTags.filter { $0 != target }
                        selectedTags = []
                        Task {
                            for source in sources {
                                await service.renameTag(from: source, to: target)
                                await tagStore.move(from: source, to: target)
                            }
                            allTags = service.noteTags()
                        }
                    }
                }
            }
            .fixedSize()
            Button("Delete All", role: .destructive) {
                let doomed = selectedTags
                selectedTags = []
                Task {
                    for tag in doomed {
                        await service.deleteTag(tag)
                    }
                    allTags = service.noteTags()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(mergeSuggestions) { merge in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(merge.from.joined(separator: ", #")) → #\(merge.into)")
                        .font(.callout)
                    HStack {
                        Text(merge.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") {
                            let suggestion = merge
                            mergeSuggestions.removeAll { $0.id == suggestion.id }
                            Task {
                                for source in suggestion.from {
                                    await service.renameTag(from: source, to: suggestion.into)
                                    await tagStore.move(from: source, to: suggestion.into)
                                }
                                allTags = service.noteTags()
                            }
                        }
                        .controlSize(.small)
                        Button("Dismiss") {
                            mergeSuggestions.removeAll { $0.id == merge.id }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Group into families")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(groupSuggestions) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(group.members.joined(separator: ", #")) → \(group.parent)/…")
                        .font(.callout)
                    HStack {
                        Text(group.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") {
                            let suggestion = group
                            groupSuggestions.removeAll { $0.id == suggestion.id }
                            Task {
                                for member in suggestion.members {
                                    let nested = TagGroup.nestedName(
                                        member: member, parent: suggestion.parent
                                    )
                                    await service.renameTag(from: member, to: nested)
                                    await tagStore.move(from: member, to: nested)
                                }
                                allTags = service.noteTags()
                            }
                        }
                        .controlSize(.small)
                        Button("Dismiss") {
                            groupSuggestions.removeAll { $0.id == group.id }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var detail: some View {
        if let selectedTag {
            tagPage(selectedTag)
        } else if selectedTags.count > 1 {
            ContentUnavailableView(
                "\(selectedTags.count) Tags Selected",
                systemImage: "number",
                description: Text("Use the bulk bar to merge or delete them together.")
            )
        } else {
            ContentUnavailableView(
                "Select a Tag",
                systemImage: "number",
                description: Text("Everything carrying the tag — notes, to-dos, and projects — appears here.")
            )
        }
    }

    /// One page per tag: description (CloudKit), then every surface the
    /// tag touches — notes, to-dos (task labels), projects.
    private func tagPage(_ tag: String) -> some View {
        let noteIds = Set(service.tagNoteIds(tag))
        let taggedNotes = model.notes.filter { noteIds.contains($0.id) }
        let tasks = service.tasksWithLabel(tag)
        let taskNoteIds = Set(tasks.map(\.noteId))
        let projects = service.projects().filter {
            noteIds.contains($0.id) || taskNoteIds.contains($0.id)
        }
        let projectIds = Set(projects.map(\.id))
        return List {
            Section("About") {
                TextField(
                    "Describe what #\(tag) is for…",
                    text: $tagDescription,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .onSubmit { commitDescription(tag) }
                if let unavailable = tagStore.unavailable {
                    Text(unavailable).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Synced via your private iCloud database.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects, id: \.id) { project in
                        Label(project.title, systemImage: "calendar.day.timeline.left")
                            .contentShape(Rectangle())
                            .onTapGesture { openNote(project.id) }
                    }
                }
            }
            if !tasks.isEmpty {
                Section("To-Dos") {
                    ForEach(tasks) { task in
                        HStack(spacing: 8) {
                            Button {
                                Task { await service.toggle(task) }
                            } label: {
                                Image(systemName: task.checked
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.checked
                                        ? Color.secondary : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help(task.checked ? "Reopen" : "Complete")
                            Text(task.text)
                                .strikethrough(task.checked)
                                .contentShape(Rectangle())
                                .onTapGesture { openTaskDetail(task) }
                            Spacer()
                            if let due = task.dueDate {
                                Text(due).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let plainNotes = taggedNotes.filter { !projectIds.contains($0.id) }
            if !plainNotes.isEmpty {
                Section("Notes") {
                    ForEach(plainNotes) { note in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    URL(fileURLWithPath: note.relativePath)
                                        .deletingPathExtension().lastPathComponent
                                )
                                let folder = note.relativePath.split(separator: "/")
                                    .dropLast().joined(separator: "/")
                                if !folder.isEmpty {
                                    Text(folder)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { openNote(note.id) }
                        .help("Open in Notes")
                    }
                }
            }
        }
        .navigationTitle("#" + tag)
        .task(id: tag) {
            descriptionTag = tag
            tagDescription = await tagStore.description(for: tag)
        }
        .onChange(of: tagDescription) {
            // Debounced-ish: commit when the user pauses via submit; also
            // commit on tag switch below.
        }
        .onDisappear { commitDescription(tag) }
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

    private func commitDescription(_ tag: String) {
        guard descriptionTag == tag else { return }
        let text = tagDescription
        Task { await tagStore.saveDescription(text, for: tag) }
    }

    private func openTaskDetail(_ task: TaskRecord) {
        #if os(macOS)
            openWindow(id: "task-detail", value: task.id)
        #else
            detailTaskId = task.id
        #endif
    }
}

import AIKit
import ConversionKit
import EditorKit
import MarkdownKit
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// The Notes tab: vault note list on the left, live markdown editor on the
/// right. Every edit autosaves (debounced, coordinated) to the .md file.
struct NotesView: View {
    let indexService: VaultIndexService
    /// Owned by AppShell: tab switches must not reset vault/tab/selection
    /// state (a fresh model also re-blocks on cold container resolution).
    let model: NotesModel
    @State private var livePreview = true
    @AppStorage("editorFocusMode") private var focusMode = false
    @State private var searchText = ""
    @State private var semanticIds: [String] = []
    @State private var showingImporter = false
    @State private var showingImagePicker = false
    @State private var showingVaultPicker = false
    @AppStorage(VaultRegistry.activeKey) private var activeVault = VaultRegistry.iCloudId
    @State private var selectedTag: String?
    @State private var allTags: [(tag: String, count: Int)] = []
    @State private var pinnedIds: [String] = []
    @State private var bookmarkedIds: [String] = []
    @AppStorage("savedNoteSearches") private var savedSearchesData = "[]"
    @State private var importStatus: String?
    @State private var aiStatus: String?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var newFolderParent = ""
    @State private var showInspector = false
    @State private var scrollTarget: NSRange?
    @State private var editorCommand: EditorCommandRequest?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
                .navigationTitle("Notes")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("New Note", systemImage: "square.and.pencil") {
                            model.createNote()
                        }
                        .keyboardShortcut("n", modifiers: [.command])
                        Button("Import Document", systemImage: "square.and.arrow.down") {
                            showingImporter = true
                        }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                        .help("Convert a PDF, image, RTF, HTML, or text file to a markdown note (⇧⌘I)")
                        Button("New Folder", systemImage: "folder.badge.plus") {
                            newFolderParent = ""
                            showingNewFolder = true
                        }
                        if !model.templates.isEmpty {
                            Menu {
                                ForEach(model.templates) { template in
                                    Button(noteTitle(template)) {
                                        model.createNote(fromTemplate: template)
                                    }
                                }
                            } label: {
                                Label("New from Template", systemImage: "doc.badge.plus")
                            }
                            .help("New note from a Templates/ file ({{title}}, {{date}}, {{time}})")
                        }
                        Button("Today", systemImage: "calendar") {
                            model.openDailyNote()
                        }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .help("Open today's daily note (⇧⌘D)")
                        #if os(macOS)
                            Menu {
                                Button {
                                    activeVault = VaultRegistry.iCloudId
                                } label: {
                                    if activeVault == VaultRegistry.iCloudId {
                                        Label("iCloud Vault", systemImage: "checkmark")
                                    } else {
                                        Text("iCloud Vault")
                                    }
                                }
                                ForEach(VaultRegistry.entries) { entry in
                                    Button {
                                        activeVault = entry.id
                                    } label: {
                                        if activeVault == entry.id {
                                            Label(entry.name, systemImage: "checkmark")
                                        } else {
                                            Text(entry.name)
                                        }
                                    }
                                }
                                Divider()
                                Button("Add Folder Vault…", systemImage: "folder.badge.plus") {
                                    showingVaultPicker = true
                                }
                            } label: {
                                Label("Vault", systemImage: "externaldrive")
                            }
                            .help("Switch between vaults or add a folder vault")
                            .fileImporter(
                                isPresented: $showingVaultPicker, allowedContentTypes: [.folder]
                            ) { outcome in
                                guard case let .success(url) = outcome,
                                      let entry = VaultRegistry.add(url: url) else { return }
                                activeVault = entry.id
                            }
                        #endif
                    }
                }
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: [
                        .pdf,
                        .image,
                        .rtf,
                        .html,
                        .plainText,
                        UTType(filenameExtension: "md") ?? .plainText,
                    ],
                    allowsMultipleSelection: true
                ) { outcome in
                    guard case let .success(urls) = outcome else { return }
                    Task {
                        for url in urls {
                            let result = await indexService.importFile(url)
                            switch result {
                            case let .success(noteId):
                                importStatus = "Imported \(noteId)"
                            case let .failure(reason):
                                importStatus = "Import failed: \(reason.message)"
                            }
                        }
                        try? await Task.sleep(for: .seconds(4))
                        importStatus = nil
                    }
                }
        } detail: {
            detail
        }
        // .searchable's toolbar item crashes the AppKit toolbar bridge on
        // the macOS 27 beta (NSToolbar insert exception) — macOS gets an
        // in-sidebar field instead; iOS keeps the system search UI.
        #if os(iOS)
        .searchable(text: $searchText, prompt: "Search all notes")
        #endif
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                model.createFolder(named: newFolderName, in: newFolderParent)
                newFolderName = ""
                newFolderParent = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .task { await model.start() }
        .task(id: searchText) {
            // Semantic results trail the instant FTS list slightly.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            semanticIds = await indexService.semanticSearchNoteIds(searchText)
        }
        .onDisappear { Task { await model.flushSave() } }
    }

    @ViewBuilder private var sidebar: some View {
        switch model.state {
        case .loading:
            ProgressView("Opening vault…")
        case let .unavailable(message):
            ContentUnavailableView(
                "iCloud Unavailable",
                systemImage: "icloud.slash",
                description: Text(message)
            )
        case .ready, .readyLocalFallback:
            // One container view: sibling views here would each receive the
            // .toolbar/.navigationTitle modifiers (duplicate buttons).
            VStack(spacing: 0) {
                #if os(macOS)
                    TextField("Search all notes", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                #endif
                noteList
            }
        }
    }

    private var noteList: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { model.select($0) }
        )) {
            if searching {
                if !savedSearches.contains(trimmedSearch) {
                    Button {
                        saveSearch(trimmedSearch)
                    } label: {
                        Label("Save this search", systemImage: "bookmark.square")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
                // Search results stay flat (ranked), with folder subtitles.
                ForEach(visibleNotes) { note in
                    noteRow(note, showFolder: true)
                }
            } else if let selectedTag {
                Section {
                    ForEach(visibleNotes) { note in
                        noteRow(note, showFolder: true)
                    }
                } header: {
                    HStack {
                        Label(selectedTag, systemImage: "number")
                        Spacer()
                        Button("Clear", systemImage: "xmark.circle.fill") {
                            self.selectedTag = nil
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                    }
                }
            } else {
                if !pinnedIds.isEmpty {
                    Section("Pinned") {
                        ForEach(notes(withIds: pinnedIds)) { note in
                            noteRow(note, showFolder: true)
                        }
                    }
                }
                if !model.recents.isEmpty {
                    Section("Recents") {
                        ForEach(notes(withIds: Array(model.recents.prefix(5)))) { note in
                            noteRow(note, showFolder: true)
                        }
                    }
                }
                if !bookmarkedIds.isEmpty {
                    Section("Bookmarks") {
                        ForEach(notes(withIds: bookmarkedIds)) { note in
                            noteRow(note, showFolder: true)
                        }
                    }
                }
                ForEach(visibleNotes.filter { !$0.relativePath.contains("/") }) { note in
                    noteRow(note, showFolder: false)
                }
                ForEach(topLevelFolders, id: \.self) { folder in
                    folderGroup(folder)
                }
                Button {
                    newFolderParent = ""
                    showingNewFolder = true
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if !allTags.isEmpty {
                    Section("Tags") {
                        ForEach(topLevelTagNodes, id: \.path) { node in
                            tagRow(node)
                        }
                    }
                }
                if !savedSearches.isEmpty {
                    Section("Saved Searches") {
                        ForEach(savedSearches, id: \.self) { query in
                            Label(query, systemImage: "magnifyingglass")
                                .contentShape(Rectangle())
                                .onTapGesture { searchText = query }
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        removeSearch(query)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .task(id: indexService.tasksVersion) {
            allTags = indexService.noteTags()
            pinnedIds = indexService.pinnedNoteIds()
            bookmarkedIds = indexService.bookmarkedNoteIds()
        }
        .overlay {
            if visibleNotes.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "note.text",
                    description: Text("Press ⌘N or tap New Note to create your first markdown note.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 2) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import Document…", systemImage: "square.and.arrow.down")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
                if let importStatus {
                    Text(importStatus)
                        .font(.caption)
                        .foregroundStyle(importStatus.contains("failed") ? .red : .secondary)
                        .padding(.bottom, 4)
                }
                if model.state == .readyLocalFallback {
                    Label("Local vault — iCloud unavailable", systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.selectedID != nil {
            VStack(spacing: 0) {
                if model.openTabs.count > 1 {
                    tabStrip
                }
                // Plain split, NOT .inspector: the system inspector's
                // toolbar/constraint integration throws during layout on
                // the macOS 27 beta (same family as the .searchable crash).
                HStack(spacing: 0) {
                    editorPane
                        .frame(minWidth: 380, idealWidth: 720, maxWidth: .infinity)
                    if showInspector {
                        Divider()
                        NoteInspector(
                            noteId: model.selectedID ?? "",
                            noteTitle: selectedTitle,
                            noteText: model.noteText,
                            service: indexService,
                            onJump: { scrollTarget = $0 },
                            onOpen: { model.select($0) }
                        )
                        .frame(width: 270)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "note.text",
                description: Text("Choose a note from the list, or create one.")
            )
        }
    }

    /// WYSIWYG affordances over plain markdown: every button writes syntax.
    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Menu {
                    Button("Title") { editorCommand = EditorCommandRequest(.setHeading(1)) }
                    Button("Heading") { editorCommand = EditorCommandRequest(.setHeading(2)) }
                    Button("Subheading") { editorCommand = EditorCommandRequest(.setHeading(3)) }
                    Divider()
                    Button("Body") { editorCommand = EditorCommandRequest(.setHeading(0)) }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .menuIndicator(.hidden)
                .help("Text style")
                Divider().frame(height: 16)
                formatButton("bold", "Bold (⌘B)") { .wrap(prefix: "**", suffix: "**") }
                    .keyboardShortcut("b", modifiers: [.command])
                formatButton("italic", "Italic (⌘⇧I)") { .wrap(prefix: "*", suffix: "*") }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                formatButton("strikethrough", "Strikethrough") { .wrap(prefix: "~~", suffix: "~~") }
                formatButton("chevron.left.forwardslash.chevron.right", "Code (⌘E)") { .wrap(prefix: "`", suffix: "`") }
                    .keyboardShortcut("e", modifiers: [.command])
                Divider().frame(height: 16)
                formatButton("list.bullet", "Bullet list") { .toggleLinePrefix("- ") }
                formatButton("list.number", "Numbered list") { .toggleLinePrefix("1. ") }
                formatButton("checklist", "To-do (⌘⇧T)") { .toggleLinePrefix("- [ ] ") }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                formatButton("quote.opening", "Quote") { .toggleLinePrefix("> ") }
                Divider().frame(height: 16)
                formatButton("link", "Link (⌘K)") { .link }
                    .keyboardShortcut("k", modifiers: [.command])
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    private func formatButton(
        _ icon: String, _ help: String, _ command: @escaping () -> EditorCommand
    ) -> some View {
        Button {
            editorCommand = EditorCommandRequest(command())
        } label: {
            Image(systemName: icon)
                .frame(width: 26, height: 22)
        }
        .help(help)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.openTabs, id: \.self) { id in
                    HStack(spacing: 4) {
                        Text(URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                        Button {
                            model.closeTab(id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .opacity(0.6)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        id == model.selectedID ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                    .onTapGesture {
                        if id != model.selectedID {
                            model.select(id)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var editorPane: some View {
        if true {
            MarkdownEditor(
                text: Binding(
                    get: { model.noteText },
                    set: { model.noteText = $0; model.textChanged() }
                ),
                scrollTarget: $scrollTarget,
                command: $editorCommand,
                livePreview: livePreview,
                focusMode: focusMode,
                imageBase: selectedNoteFolder,
                tagCandidates: allTags.map(\.tag),
                linkCandidates: model.notes.map(noteTitle)
            )
            .safeAreaInset(edge: .top, spacing: 0) { formatBar }
            .overlay(alignment: .bottomTrailing) {
                Text(statsChip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Summarize Note", systemImage: "text.append") {
                            runAI(summarize: true)
                        }
                        Button("Extract Action Items", systemImage: "checklist") {
                            runAI(summarize: false)
                        }
                        if let aiStatus {
                            Divider()
                            Text(aiStatus)
                        }
                    } label: {
                        Label("AI", systemImage: "sparkles")
                    }
                    .disabled(aiStatus?.hasSuffix("…") == true)
                    Button("Info", systemImage: "sidebar.right") {
                        showInspector.toggle()
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .help("Outline, backlinks & mentions (⌥⌘0)")
                    Menu {
                        Button("Table", systemImage: "tablecells") {
                            editorCommand = EditorCommandRequest(.insertBlock(
                                "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |",
                                cursorOffset: 2
                            ))
                        }
                        Button("Image…", systemImage: "photo") {
                            showingImagePicker = true
                        }
                        Button("Horizontal Rule", systemImage: "minus") {
                            editorCommand = EditorCommandRequest(.insertBlock("---", cursorOffset: nil))
                        }
                    } label: {
                        Label("Insert", systemImage: "plus.square")
                    }
                    .help("Insert a table, image, or divider")
                    .fileImporter(
                        isPresented: $showingImagePicker, allowedContentTypes: [.image]
                    ) { outcome in
                        guard case let .success(url) = outcome else { return }
                        Task {
                            guard let path = await model.attachImage(from: url) else {
                                importStatus = "Image attach failed"
                                return
                            }
                            let alt = url.deletingPathExtension().lastPathComponent
                            editorCommand = EditorCommandRequest(.insertBlock(
                                "![\(alt)](\(path))", cursorOffset: nil
                            ))
                        }
                    }
                    if let day = model.openDailyNoteDate {
                        Button("Previous Day", systemImage: "chevron.backward") {
                            model.openDailyNote(
                                for: Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
                            )
                        }
                        Button("Next Day", systemImage: "chevron.forward") {
                            model.openDailyNote(
                                for: Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
                            )
                        }
                    }
                    Button("Focus", systemImage: focusMode ? "circle.circle.fill" : "circle.circle") {
                        focusMode.toggle()
                    }
                    .help(focusMode ? "Focus mode on — dims other paragraphs" : "Focus mode")
                    Button(
                        livePreview ? "Source Mode" : "Live Preview",
                        systemImage: livePreview ? "chevron.left.forwardslash.chevron.right" : "eye"
                    ) {
                        livePreview.toggle()
                    }
                    .keyboardShortcut("/", modifiers: [.command])
                    .help(livePreview
                        ? "Show all markdown syntax (⌘/)"
                        : "Hide syntax except on the current line (⌘/)")
                }
            }
            .navigationTitle(selectedTitle)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    /// AI actions edit the note text like any other edit — autosave and the
    /// indexer treat the result exactly as if the user typed it.
    private func runAI(summarize: Bool) {
        let source = model.noteText
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        aiStatus = summarize ? "Summarizing…" : "Extracting…"
        Task {
            var providers: [any AIProvider] = []
            #if canImport(FoundationModels)
                providers.append(FoundationModelsProvider())
            #endif
            if let urlString = UserDefaults.standard.string(forKey: "ollamaURL"),
               let url = ServerURL.normalize(urlString) {
                let model = UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3"
                providers.append(OllamaProvider(baseURL: url, model: model.isEmpty ? "qwen3" : model))
            }
            let router = AIRouter(providers: providers)
            do {
                if summarize {
                    let (summary, provider) = try await router.summarize(source)
                    let block = "> **Summary** *(\(provider))*: \(summary)\n\n"
                    let doc = MarkdownDocument(source: source)
                    model.noteText = (doc.frontmatter?.rawBlock ?? "") + block + doc.body
                } else {
                    let (tasks, provider) = try await router.extractActionItems(from: source)
                    guard !tasks.isEmpty else {
                        aiStatus = "No action items found"
                        try? await Task.sleep(for: .seconds(3))
                        aiStatus = nil
                        return
                    }
                    let section = "\n## Action Items *(\(provider))*\n\n"
                        + tasks.map(\.markdownLine).joined(separator: "\n") + "\n"
                    model.noteText = source + section
                }
                model.textChanged()
                aiStatus = "Done (\(summarize ? "summary" : "action items") added)"
            } catch {
                aiStatus = "AI failed: \(error)"
            }
            try? await Task.sleep(for: .seconds(3))
            aiStatus = nil
        }
    }

    /// One node per distinct tag path component; counts include nested tags.
    private struct TagNode {
        let path: String
        let name: String
        let count: Int
        let children: [TagNode]
    }

    private var topLevelTagNodes: [TagNode] {
        Self.tagNodes(under: "", from: allTags)
    }

    private static func tagNodes(
        under prefix: String, from tags: [(tag: String, count: Int)]
    ) -> [TagNode] {
        let depth = prefix.isEmpty ? 0 : prefix.split(separator: "/").count
        var names: [String] = []
        var seen = Set<String>()
        for (tag, _) in tags where prefix.isEmpty || tag == prefix || tag.hasPrefix(prefix + "/") {
            let parts = tag.split(separator: "/")
            guard parts.count > depth else { continue }
            let name = String(parts[depth])
            if seen.insert(name).inserted { names.append(name) }
        }
        return names.map { name in
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let count = tags
                .filter { $0.tag == path || $0.tag.hasPrefix(path + "/") }
                .reduce(0) { $0 + $1.count }
            return TagNode(
                path: path, name: name, count: count,
                children: tagNodes(under: path, from: tags)
            )
        }
    }

    // AnyView: the tree is recursive; opaque return types can't be
    // self-referential (same pattern as folderGroup).
    private func tagRow(_ node: TagNode) -> AnyView {
        if node.children.isEmpty {
            AnyView(tagLabel(node))
        } else {
            AnyView(DisclosureGroup {
                ForEach(node.children, id: \.path) { child in
                    tagRow(child)
                }
            } label: {
                tagLabel(node)
            })
        }
    }

    private func tagLabel(_ node: TagNode) -> some View {
        HStack {
            Label(node.name, systemImage: "number")
            Spacer()
            Text("\(node.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedTag = node.path }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var savedSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(savedSearchesData.utf8))) ?? []
    }

    private func saveSearch(_ query: String) {
        guard !query.isEmpty else { return }
        let updated = savedSearches.filter { $0 != query } + [query]
        savedSearchesData = (try? JSONEncoder().encode(updated))
            .flatMap { String(data: $0, encoding: .utf8) } ?? savedSearchesData
    }

    private func removeSearch(_ query: String) {
        let updated = savedSearches.filter { $0 != query }
        savedSearchesData = (try? JSONEncoder().encode(updated))
            .flatMap { String(data: $0, encoding: .utf8) } ?? savedSearchesData
    }

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var topLevelFolders: [String] {
        model.folders.filter { !$0.contains("/") }
    }

    private func subfolders(of folder: String) -> [String] {
        model.folders.filter {
            $0.hasPrefix(folder + "/") && !$0.dropFirst(folder.count + 1).contains("/")
        }
    }

    private func notes(withIds ids: [String]) -> [VaultItem] {
        let byId = Dictionary(uniqueKeysWithValues: model.notes.map { ($0.id, $0) })
        return ids.compactMap { byId[$0] }
    }

    private func notes(in folder: String) -> [VaultItem] {
        visibleNotes.filter {
            let dir = $0.relativePath.split(separator: "/").dropLast().joined(separator: "/")
            return dir == folder
        }
    }

    private func folderGroup(_ folder: String) -> AnyView {
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        return AnyView(
            DisclosureGroup {
                ForEach(notes(in: folder)) { note in
                    noteRow(note, showFolder: false)
                }
                ForEach(subfolders(of: folder), id: \.self) { child in
                    folderGroup(child)
                }
            } label: {
                Label(name, systemImage: "folder")
                    .contextMenu {
                        Button("New Note Here", systemImage: "square.and.pencil") {
                            model.createNote(in: folder)
                        }
                        Button("New Subfolder…", systemImage: "folder.badge.plus") {
                            newFolderParent = folder
                            showingNewFolder = true
                        }
                    }
            }
        )
    }

    private func noteRow(_ note: VaultItem, showFolder: Bool) -> some View {
        // Plain tagged row: NavigationLink(value:) here makes SwiftUI infer
        // a 3-column split with an empty middle pane. Selection drives all.
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(noteTitle(note))
                if showFolder, let folder = noteFolder(note) {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            syncBadge(note)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(
                pinnedIds.contains(note.id) ? "Unpin" : "Pin",
                systemImage: pinnedIds.contains(note.id) ? "pin.slash" : "pin"
            ) {
                Task {
                    await indexService.setNoteFlag(
                        note.id, key: "pinned", value: !pinnedIds.contains(note.id)
                    )
                }
            }
            Button(
                bookmarkedIds.contains(note.id) ? "Remove Bookmark" : "Bookmark",
                systemImage: bookmarkedIds.contains(note.id) ? "bookmark.slash" : "bookmark"
            ) {
                Task {
                    await indexService.setNoteFlag(
                        note.id, key: "bookmarked", value: !bookmarkedIds.contains(note.id)
                    )
                }
            }
        }
        .tag(note.id)
        .contextMenu {
            Menu("Move To") {
                Button("Vault Root") { model.move(note, toFolder: "") }
                ForEach(model.folders, id: \.self) { folder in
                    Button(folder) { model.move(note, toFolder: folder) }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.delete(note)
            }
        }
    }

    /// FTS-ranked results first, semantic (meaning-based) extras after.
    private var visibleNotes: [VaultItem] {
        if let selectedTag, !searching {
            let ids = Set(indexService.tagNoteIds(selectedTag))
            return model.notes.filter { ids.contains($0.id) }
        }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return model.notes }
        let ranked = indexService.searchNoteIds(searchText)
        let merged = ranked + semanticIds.filter { !ranked.contains($0) }
        let byId = Dictionary(uniqueKeysWithValues: model.notes.map { ($0.id, $0) })
        return merged.compactMap { byId[$0] }
    }

    /// The selected note's folder — base for relative image paths.
    private var selectedNoteFolder: URL? {
        guard let root = model.root, let id = model.selectedID else { return nil }
        return root.appendingPathComponent(id).deletingLastPathComponent()
    }

    private var selectedTitle: String {
        model.notes.first { $0.id == model.selectedID }.map(noteTitle) ?? "Note"
    }

    private var wordCount: Int {
        model.noteText.split(whereSeparator: \.isWhitespace).count
    }

    private var statsChip: String {
        let words = wordCount
        guard words > 0 else { return "0 words" }
        // ~220 wpm silent-reading average; floor at one minute.
        let minutes = max(1, Int((Double(words) / 220.0).rounded()))
        return "\(words) words · \(minutes) min read"
    }

    private func noteTitle(_ note: VaultItem) -> String {
        URL(fileURLWithPath: note.relativePath).deletingPathExtension().lastPathComponent
    }

    private func noteFolder(_ note: VaultItem) -> String? {
        let components = note.relativePath.split(separator: "/").dropLast()
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// Makes iCloud transit visible: slow sync should read as "in flight",
    /// never as "broken". No badge = fully synced.
    @ViewBuilder private func syncBadge(_ note: VaultItem) -> some View {
        if note.hasUnresolvedConflicts {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
                .help("Sync conflict — resolve in the Vault tab")
        } else if note.isUploading {
            Image(systemName: "icloud.and.arrow.up")
                .foregroundStyle(.secondary)
                .help("Uploading to iCloud…")
        } else if note.downloadState == .notDownloaded {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
                .help("Not downloaded yet")
        } else if note.downloadState == .downloaded {
            Image(systemName: "arrow.clockwise.icloud")
                .foregroundStyle(.secondary)
                .help("Newer version syncing down…")
        }
    }
}

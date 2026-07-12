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
    @State private var model = NotesModel()
    @State private var livePreview = true
    @State private var searchText = ""
    @State private var semanticIds: [String] = []
    @State private var showingImporter = false
    @State private var importStatus: String?
    @State private var aiStatus: String?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var showInspector = false
    @State private var scrollTarget: NSRange?

    var body: some View {
        NavigationSplitView {
            sidebar
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
                            showingNewFolder = true
                        }
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
                model.createFolder(named: newFolderName)
                newFolderName = ""
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
                // Search results stay flat (ranked), with folder subtitles.
                ForEach(visibleNotes) { note in
                    noteRow(note, showFolder: true)
                }
            } else {
                ForEach(visibleNotes.filter { !$0.relativePath.contains("/") }) { note in
                    noteRow(note, showFolder: false)
                }
                ForEach(topLevelFolders, id: \.self) { folder in
                    folderGroup(folder)
                }
            }
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
                livePreview: livePreview
            )
            .overlay(alignment: .bottomTrailing) {
                Text("\(wordCount) words")
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
            }
        )
    }

    private func noteRow(_ note: VaultItem, showFolder: Bool) -> some View {
        NavigationLink(value: note.id) {
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
        }
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
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return model.notes }
        let ranked = indexService.searchNoteIds(searchText)
        let merged = ranked + semanticIds.filter { !ranked.contains($0) }
        let byId = Dictionary(uniqueKeysWithValues: model.notes.map { ($0.id, $0) })
        return merged.compactMap { byId[$0] }
    }

    private var selectedTitle: String {
        model.notes.first { $0.id == model.selectedID }.map(noteTitle) ?? "Note"
    }

    private var wordCount: Int {
        model.noteText.split(whereSeparator: \.isWhitespace).count
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

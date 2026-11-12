import AIKit
#if os(macOS)
    import AppKit
#endif
import ConversionKit
import EditorKit
import IndexKit
import MarkdownKit
import ProofKit
import ReadingKit
import SecurityKit
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// Reading mode's top-visible line, kept OUTSIDE SwiftUI state: it changes
/// on every scroll frame and a `@State` write would re-run the whole detail
/// pane's body each time. Only the mode switch ever reads it.
@MainActor
final class ReadingPositionBox {
    var topLine = 0
}

/// The Notes tab: vault note list on the left, live markdown editor on the
/// right. Every edit autosaves (debounced, coordinated) to the .md file.
struct NotesView: View {
    let indexService: VaultIndexService
    /// Owned by AppShell: tab switches must not reset vault/tab/selection
    /// state (a fresh model also re-blocks on cold container resolution).
    let model: NotesModel
    /// Menu-bar commands: this view performs the Notes-tab scopes and
    /// publishes what is enabled (see `ShellCommandBus`).
    let commands: ShellCommandBus
    /// Remembered globally (Obsidian's default); per-note memory is a
    /// deliberate non-goal for now.
    @AppStorage("editorMode") private var editorMode = EditorMode.live
    /// One-shot scroll target for Reading mode (line), consumed by the view.
    @State private var readingScrollLine: Int?
    @State private var readingPosition = ReadingPositionBox()
    @AppStorage("editorFocusMode") private var focusMode = false
    /// Per-mode font design + size (spec 04) — Live keeps the legacy keys,
    /// Source and Reading get their own. `EditorFontPreferences.keys(for:)`
    /// is the single source of truth for the key strings.
    @AppStorage(EditorFontPreferences.keys(for: .live).design) private var editorFontDesign = EditorFontPreferences
        .defaultDesign
    @AppStorage(EditorFontPreferences.keys(for: .live).size) private var editorFontSize = Double(EditorFontPreferences
        .defaultSize)
    @AppStorage(EditorFontPreferences.keys(for: .source).design) private var sourceFontDesign = EditorFontPreferences
        .defaultDesign
    @AppStorage(EditorFontPreferences.keys(for: .source).size) private var sourceFontSize = Double(EditorFontPreferences
        .defaultSize)
    @AppStorage(EditorFontPreferences.keys(for: .reading).design) private var readingFontDesign = EditorFontPreferences
        .defaultDesign
    @AppStorage(EditorFontPreferences.keys(for: .reading).size) private var readingFontSize =
        Double(EditorFontPreferences.defaultSize)
    @AppStorage("findHighlightColor") private var findHighlightColor = "yellow"
    /// Heading size as a percent of the default enlargement, all modes.
    @AppStorage("headingScale") private var headingScalePercent = 100.0
    /// Summaries / action items: the homelab Ollama model first, Apple
    /// Intelligence as the fallback (user request). Off = on-device first.
    @AppStorage("aiPreferOllama") private var aiPreferOllama = true
    // Proofing — Settings ▸ Editor ▸ Proofing owns these three; the editor
    // applies them live on every update.
    @AppStorage("proofSpelling") private var proofSpelling = true
    @AppStorage("proofGrammar") private var proofGrammar = true
    @AppStorage("proofAutocorrect") private var proofAutocorrect = false
    @State private var semanticIds: [String] = []
    @State private var showingImporter = false
    @State private var showingImagePicker = false
    @State private var showingVaultPicker = false
    @State private var showingVaultImporter = false
    @AppStorage(VaultRegistry.activeKey) private var activeVault = VaultRegistry.iCloudId
    @State private var allTags: [(tag: String, count: Int)] = []
    @State private var pinnedIds: [String] = []
    @State private var bookmarkedIds: [String] = []
    @State private var favoriteIds: [String] = []
    @State private var areas: [String: [String]] = [:]
    @State private var newAreaTarget: String?
    @State private var newAreaName = ""
    @AppStorage("savedNoteSearches") private var savedSearchesData = "[]"
    @AppStorage("favoriteFolders") private var favoriteFoldersData = "[]"
    /// Sidebar state that has to survive a tab switch lives on the model, not here: the Notes tab
    /// is unmounted while another tab shows, and `@State` went with it (spec ux-phase2/03).
    private var searchText: String {
        get { model.sidebar.searchText }
        nonmutating set { model.sidebar.searchText = newValue }
    }

    private var selectedTag: String? {
        get { model.sidebar.selectedTag }
        nonmutating set { model.sidebar.selectedTag = newValue }
    }

    private var tagsExpanded: Bool {
        get { model.sidebar.tagsExpanded }
        nonmutating set { model.sidebar.tagsExpanded = newValue }
    }

    /// List selection for VAULT rows only; decoupled from model.selectedID
    /// so a click in Favorites/Recents highlights THAT row instead.
    private var listSelection: String? {
        get { model.sidebar.listSelection }
        nonmutating set { model.sidebar.listSelection = newValue }
    }

    /// "section|noteId" of the clicked section row, nil when the Vault
    /// list owns the highlight.
    private var sectionHighlight: String? {
        get { model.sidebar.sectionHighlight }
        nonmutating set { model.sidebar.sectionHighlight = newValue }
    }

    /// Open folders persist across relaunches too (a JSON array like `favoriteFolders`). Entries
    /// are `section|folder` keys; one for a folder that no longer exists is simply never asked for.
    @AppStorage("ui.notes.expandedFolders") private var expandedFoldersData = "[]"
    private var expandedFolders: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: Data(expandedFoldersData.utf8))) ?? []) }
        nonmutating set {
            expandedFoldersData = (try? JSONEncoder().encode(newValue.sorted()))
                .flatMap { String(data: $0, encoding: .utf8) } ?? expandedFoldersData
        }
    }

    @State private var importStatus: String?
    @State private var aiStatus: String?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var newFolderParent = ""
    #if os(macOS)
        @AppStorage("ui.notes.inspector") private var showInspector = false
    #else
        @State private var showInspector = false
    #endif
    @State private var scrollTarget: NSRange?
    @State private var editorCommand: EditorCommandRequest?
    @State private var findSignal = 0
    /// Format-bar active state — published by the editor on every caret
    /// move, macOS-first (see EditorKit.SelectionContext).
    @State private var selectionContext = SelectionContext()
    @State private var showingLinkPopover = false
    /// The link's full `[text](url)` range AND its exact source text,
    /// captured when the editor sheet opened — Save/Remove target the
    /// range only while the document still holds that source there (the
    /// note can change underneath an open sheet via sync), so a drifted
    /// document makes the edit a no-op instead of a mid-word rewrite.
    @State private var linkEditRange: NSRange?
    @State private var linkEditSource = ""
    @State private var linkPopoverText = ""
    @State private var linkPopoverURL = ""
    @State private var showingGraph = false
    /// Delete flow (spec ux-phase1/01): the note awaiting the Move to Trash confirmation, and
    /// the Trash sheet. One confirmationDialog drives the former; it is not an `.alert`.
    @State private var trashCandidate: VaultItem?
    @State private var showingTrash = false
    /// The note whose sync conflict the sheet is resolving (spec ux-phase1/05).
    @State private var conflictNote: VaultItem?
    /// Rename flow (spec ux-phase2/05): the note the Rename sheet is for, and the inbound notes
    /// whose link rewrite failed (the Try Again alert).
    @State private var renameCandidate: VaultItem?
    /// The inbound-link rewrite that follows a rename, which keeps going after the sheet closes.
    @State private var linkRewriteTask: Task<Void, Never>?
    @State private var linkRetry: LinkRetry?
    /// An unresolved ⌘-clicked / tapped wikilink awaiting "Create Note" (spec ux-phase2/06).
    @State private var createLinkCandidate: Wikilink?
    @State private var showingLockSheet = false
    @State private var showingUnlockSheet = false
    @State private var lockPassphrase = ""
    @State private var lockConfirm = ""
    @State private var lockError: String?
    @AppStorage("noteSortOrder") private var noteSortOrder = "name"
    // Proofread (LanguageTool) — spec 02.
    @State private var showingProofread = false
    @State private var proofreadState = ProofreadState.idle
    @State private var proofreadRows: [ProofreadRow] = []
    @State private var proofreadTask: Task<Void, Never>?
    /// "Ignore rule for this session" — deliberately not persisted.
    @State private var ignoredProofreadRuleIds: Set<String> = []
    @AppStorage("languageToolLanguage") private var languageToolLanguage = "auto"

    var body: some View {
        notesContent
            .task {
                // After the appear, so a vault switch (old view out, new view
                // in) cannot leave the flag false.
                publishCommandState()
            }
            .onAppear { publishCommandState() }
            .onDisappear { commands.publish(\.notesTabVisible, false) }
            .onChange(of: model.selectedID) { publishCommandState() }
            .onChange(of: model.lockedPlaceholder) { publishCommandState() }
            .onChange(of: editorMode) { publishCommandState() }
            .onChange(of: model.selectedIsLockable) { publishCommandState() }
            .onChange(of: languageToolConfigured) { publishCommandState() }
            .onChange(of: showInspector) { publishCommandState() }
            .onReceive(windowDidBecomeKey) { _ in publishCommandState() }
            .onChange(of: commands.requestID) {
                guard let command = commands.pending, command.scope != .shell else { return }
                performMenuCommand(command)
            }
    }

    /// The LanguageTool URL is saved in the Settings window, which never
    /// re-renders this view: the menu re-reads it when a window takes key.
    private var windowDidBecomeKey: NotificationCenter.Publisher {
        #if os(macOS)
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        #else
            // The command bus is macOS-only in effect; nothing to re-read.
            NotificationCenter.default.publisher(for: Notification.Name("NotetakerWindowKeyIsMacOnly"))
        #endif
    }

    private var notesContent: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
                .navigationTitle("Notes")
                .settingsButton()
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
        .searchable(text: Bindable(model).sidebar.searchText, prompt: "Search all notes")
        #endif
        // Two alerts must NOT share one attachment point — SwiftUI honors
        // only one .alert per view (New Folder went dead, user-reported).
        .background(
            EmptyView().alert(
                "New Area",
                isPresented: Binding(
                    get: { newAreaTarget != nil },
                    set: {
                        if !$0 {
                            newAreaTarget = nil
                        }
                    }
                )
            ) {
                TextField("Area name (e.g. Work, Personal)", text: $newAreaName)
                Button("Create & Assign") {
                    if let noteId = newAreaTarget {
                        let name = newAreaName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty {
                            Task {
                                await indexService.setFrontmatterValue(
                                    noteId, key: "area", value: name
                                )
                            }
                        }
                    }
                    newAreaTarget = nil
                }
                Button("Cancel", role: .cancel) { newAreaTarget = nil }
            } message: {
                Text("Areas are high-level topics that group notes across folders.")
            }
        )
        .background(
            EmptyView().alert("New Folder", isPresented: $showingNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    model.createFolder(named: newFolderName, in: newFolderParent)
                    newFolderName = ""
                    newFolderParent = ""
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
        )
        .task { await model.start() }
        .task(id: searchText) {
            // Semantic results trail the instant FTS list slightly.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            semanticIds = await indexService.semanticSearchNoteIds(searchText)
        }
        .onDisappear { Task { await model.flushSave() } }
        .sheet(isPresented: $showingLockSheet) { lockSheet }
        .sheet(isPresented: $showingProofread) { proofreadSheet }
        .sheet(isPresented: $showingTrash) {
            TrashSheet(model: model, indexService: indexService)
        }
        .sheet(item: $conflictNote) { note in
            ConflictSheet(note: note, model: model) {
                await indexService.rescan()
            }
        }
        .sheet(item: $renameCandidate) { note in
            RenameNoteSheet(note: note, model: model, indexService: indexService) { name in
                await performRename(note, to: name)
            }
        }
        .background(
            EmptyView().alert(
                "Some Links Weren't Updated",
                isPresented: Binding(
                    get: { linkRetry != nil },
                    set: {
                        if !$0 {
                            linkRetry = nil
                        }
                    }
                ),
                presenting: linkRetry
            ) { retry in
                Button("Try Again") {
                    Task {
                        await rewriteInboundLinks(
                            for: retry.receipt, pool: retry.pool, only: Set(retry.failed.map(\.id))
                        )
                    }
                }
                Button("OK", role: .cancel) { linkRetry = nil }
            } message: { retry in
                Text(
                    "These notes still link to “\(retry.receipt.oldTitle)”:\n"
                        + retry.failed.map { "\($0.title): \($0.reason)" }.joined(separator: "\n")
                )
            }
        )
        .confirmationDialog(
            trashCandidate.map { "Move “\(noteTitle($0))” to Trash?" } ?? "Move to Trash?",
            isPresented: Binding(
                get: { trashCandidate != nil },
                set: {
                    if !$0 {
                        trashCandidate = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: trashCandidate
        ) { note in
            Button("Move to Trash", role: .destructive) {
                Task {
                    await model.moveToTrash(note)
                    await indexService.rescan()
                }
            }
        } message: { _ in
            Text("You can undo this right away, or restore it later from the Trash.")
        }
        .sheet(isPresented: $showingGraph) {
            GraphView(
                notes: model.notes.map { ($0.id, noteTitle($0)) },
                links: indexService.allOutLinks()
            ) { id in
                model.openNote(id, jumpToLine: nil)
            }
        }
        // Handoff: the open note is continuable on another device.
        .userActivity("com.rchaight.notetaker.note", isActive: model.selectedID != nil) { activity in
            activity.title = selectedTitle
            activity.userInfo = ["noteId": model.selectedID ?? ""]
            activity.isEligibleForHandoff = true
        }
        .onContinueUserActivity("com.rchaight.notetaker.note") { activity in
            if let id = activity.userInfo?["noteId"] as? String, !id.isEmpty {
                model.openNote(id, jumpToLine: nil)
            }
        }
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
                    TextField("Search all notes", text: Bindable(model).sidebar.searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                #endif
                sidebarActionBar
                noteList
            }
        }
    }

    /// Compact icon strip over the note list (user-requested, Obsidian-ish):
    /// new note · import document · add files/folders · sort · collapse.
    private var sidebarActionBar: some View {
        HStack(spacing: 4) {
            actionIcon("square.and.pencil", "New note (⌘N)") {
                model.createNote()
            }
            sidebarMoreMenu
            actionIcon("square.and.arrow.down", "Import a document (convert to markdown)") {
                showingImporter = true
            }
            actionIcon("folder.badge.plus", "Add existing notes/folders to the vault") {
                showingVaultImporter = true
            }
            Spacer()
            if model.refreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .help("Refreshing from iCloud…")
            } else {
                actionIcon("arrow.clockwise", "Refresh notes from iCloud (⌘R)") {
                    Task { await refreshVault() }
                }
            }
            Menu {
                Picker("Sort", selection: $noteSortOrder) {
                    Label("Name", systemImage: "textformat").tag("name")
                    Label("Recently modified", systemImage: "clock").tag("modified")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Sort order")
            actionIcon("rectangle.compress.vertical", "Collapse all folders") {
                expandedFolders.removeAll()
            }
            actionIcon("trash", "Trash — restore or permanently delete notes") {
                showingTrash = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// New Folder / templates / daily note / vault switching. These lived
    /// in the sidebar's `.toolbar`; the window toolbar is hidden on macOS
    /// (its strip drew over the editor's format bar — user report), so
    /// everything it carried lives in-content now.
    private var sidebarMoreMenu: some View {
        Menu {
            Button("New Folder…", systemImage: "folder.badge.plus") {
                newFolderParent = ""
                showingNewFolder = true
            }
            if !model.templates.isEmpty {
                Menu("New from Template") {
                    ForEach(model.templates) { template in
                        Button(noteTitle(template)) {
                            model.createNote(fromTemplate: template)
                        }
                    }
                }
            }
            Button("Today's Daily Note (⇧⌘D)", systemImage: "calendar") {
                model.openDailyNote()
            }
            #if os(macOS)
                Divider()
                Menu("Vault") {
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
                }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("New folder, templates, daily note, vaults")
        #if os(macOS)
            .fileImporter(
                isPresented: $showingVaultPicker, allowedContentTypes: [.folder]
            ) { outcome in
                guard case let .success(url) = outcome,
                      let entry = VaultRegistry.add(url: url) else { return }
                activeVault = entry.id
            }
        #endif
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

    private var noteList: some View {
        List(selection: Binding(
            get: { listSelection },
            set: { id in
                listSelection = id
                sectionHighlight = nil
                if let id {
                    model.select(id)
                }
            }
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
                // Layout per user direction: Favorites, Recents, then the
                // full vault (root notes + folders); curated sections follow.
                if !favoriteIds.isEmpty || !favoriteFolders.isEmpty {
                    Section("Favorites") {
                        ForEach(favoriteFolders.filter { model.folders.contains($0) }, id: \.self) { folder in
                            folderGroup(folder, selectable: false, section: "favfolder")
                        }
                        ForEach(notes(withIds: favoriteIds)) { note in
                            noteRow(note, showFolder: true, selectable: false, section: "fav")
                        }
                    }
                }
                // The newest-modified notes from any device, not the ones opened here
                // (the opened-on-this-device list hid edits made on the Mac).
                if !model.notesByModified.isEmpty {
                    Section("Recents") {
                        ForEach(Array(model.notesByModified.prefix(5))) { note in
                            noteRow(note, showFolder: true, selectable: false, section: "recent")
                        }
                    }
                }
                if !areas.isEmpty {
                    Section("Areas") {
                        ForEach(areas.keys.sorted(), id: \.self) { area in
                            DisclosureGroup {
                                ForEach(notes(withIds: areas[area] ?? [])) { note in
                                    noteRow(note, showFolder: true, selectable: false, section: "area-" + area)
                                }
                            } label: {
                                HStack {
                                    Label(area, systemImage: "square.grid.2x2")
                                    Spacer()
                                    Text("\(areas[area]?.count ?? 0)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .selectionDisabled(true)
                                .dropDestination(for: String.self) { ids, _ in
                                    // Drop a note onto an area to assign it.
                                    for id in ids {
                                        Task {
                                            await indexService.setFrontmatterValue(
                                                id, key: "area", value: area
                                            )
                                        }
                                    }
                                    return !ids.isEmpty
                                }
                            }
                        }
                    }
                }
                Section {
                    EmptyView()
                } header: {
                    Text("Vault")
                        .dropDestination(for: String.self) { ids, _ in
                            var moved = false
                            for id in ids {
                                if let note = model.notes.first(where: { $0.id == id }) {
                                    model.move(note, toFolder: "")
                                    moved = true
                                }
                            }
                            return moved
                        }
                }
                Section {
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
                }
                if !pinnedIds.isEmpty {
                    Section("Pinned") {
                        ForEach(notes(withIds: pinnedIds)) { note in
                            noteRow(note, showFolder: true, selectable: false, section: "pin")
                        }
                    }
                }
                if !bookmarkedIds.isEmpty {
                    Section("Bookmarks") {
                        ForEach(notes(withIds: bookmarkedIds)) { note in
                            noteRow(note, showFolder: true, selectable: false, section: "book")
                        }
                    }
                }
                if !allTags.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: Bindable(model).sidebar.tagsExpanded) {
                            ForEach(topTags, id: \.tag) { entry in
                                tagChipRow(entry.tag, count: entry.count)
                            }
                            Text("Manage all \(allTags.count) tags in the Tags tab")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } label: {
                            Label("Tags", systemImage: "number")
                                .selectionDisabled(true)
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
        .onAppear {
            // Another tab may have opened a different note since a Favorites/Recents row was
            // clicked; that highlight belongs to the old note, so the Vault list takes over.
            if let highlight = sectionHighlight, !highlight.hasSuffix("|" + (model.selectedID ?? "")) {
                sectionHighlight = nil
            }
            if sectionHighlight == nil {
                listSelection = model.selectedID
            }
        }
        // Pull down on the list to pull from iCloud (iOS gesture; on macOS
        // the action bar's ⌘R button runs the same refresh).
        .refreshable { await refreshVault() }
        // Periodic catch-up. The metadata watcher already pushes most
        // changes, but it can miss a device that syncs while the app is
        // backgrounded, so poll as a backstop. `apply` drops no-op snapshots,
        // so a tick with nothing new never disturbs the list or the selection.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await refreshVault()
            }
        }
        .onChange(of: model.noteText) {
            // A cross-tab line jump, or a wikilink's #heading / #^block anchor (spec 06),
            // resolved against the text that just loaded. A missing anchor opens at the top.
            let anchor = model.consumeJumpAnchor()
            guard let line = model.consumeJumpLine() ?? anchor.flatMap({
                WikilinkSyntax.anchorLine(heading: $0.heading, blockId: $0.blockId, in: model.noteText)
            }) else { return }
            jump(toLine: line)
        }
        .onChange(of: model.selectedID) {
            if sectionHighlight == nil {
                listSelection = model.selectedID
            }
        }
        .task(id: indexService.tasksVersion) {
            allTags = indexService.noteTags()
            pinnedIds = indexService.pinnedNoteIds()
            bookmarkedIds = indexService.bookmarkedNoteIds()
            favoriteIds = indexService.favoriteNoteIds()
            areas = indexService.areaAssignments()
            // The Note menu's Make / Remove Project title follows the index.
            publishCommandState()
        }
        .overlay {
            if visibleNotes.isEmpty {
                emptyListState
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 2) {
                trashNotice
                renameNotice
                EmptyView()
                    .fileImporter(
                        isPresented: $showingVaultImporter,
                        allowedContentTypes: [
                            .folder, .plainText,
                            UTType(filenameExtension: "md") ?? .plainText,
                            UTType(filenameExtension: "markdown") ?? .plainText,
                        ],
                        allowsMultipleSelection: true
                    ) { outcome in
                        guard case let .success(urls) = outcome else { return }
                        Task {
                            importStatus = await model.importIntoVault(urls: urls)
                            try? await Task.sleep(for: .seconds(4))
                            importStatus = nil
                        }
                    }
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
            // The Undo toast (and any trash failure) clears itself after 6 s. Keyed on the
            // receipt, so a newer toast restarts the timer and Undo (receipt -> nil) cancels it.
            .task(id: model.lastTrashed) {
                guard model.lastTrashed != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                model.dismissTrashNotice()
            }
            .task(id: model.trashFailure) {
                guard model.trashFailure != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                model.dismissTrashNotice()
            }
            // Rename's Undo toast: the same 6 s, counted from when the sheet (and any Try Again
            // alert) is gone, so the window to undo isn't spent behind them.
            .task(id: renameToastKey) {
                guard model.lastRenamed != nil, renameCandidate == nil, linkRetry == nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                model.dismissRenameNotice()
            }
            .task(id: model.renameFailure) {
                guard model.renameFailure != nil, model.lastRenamed == nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                model.dismissRenameNotice()
            }
        }
    }

    private var renameToastKey: String? {
        model.lastRenamed.map { "\($0.oldId)|\($0.newId)|\(renameCandidate == nil && linkRetry == nil)" }
    }

    /// "Renamed “Plan” to “Plan 2026” — Undo", or why a rename's follow-up failed. Same look
    /// as `trashNotice`.
    @ViewBuilder private var renameNotice: some View {
        if let receipt = model.lastRenamed {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                Text("Renamed “\(receipt.oldTitle)” to “\(receipt.newTitle)”")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Undo") { undoRename() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.headerBackground, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        if let failure = model.renameFailure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
    }

    /// Search with no hits is "No Results", a tag with no notes says so, and only a vault with
    /// no notes at all gets the onboarding hint (spec ux-phase1/06f).
    @ViewBuilder private var emptyListState: some View {
        if searching {
            ContentUnavailableView.search(text: searchText)
        } else if let selectedTag {
            ContentUnavailableView(
                "No Notes",
                systemImage: "number",
                description: Text("No notes tagged #\(selectedTag)")
            )
        } else if model.notes.isEmpty {
            ContentUnavailableView(
                "No Notes Yet",
                systemImage: "note.text",
                description: Text(newNoteHint)
            )
        }
    }

    private var newNoteHint: String {
        #if os(macOS)
            "Press ⌘N or choose New Note to create your first markdown note."
        #else
            "Tap New Note to create your first markdown note."
        #endif
    }

    /// "Moved “Plan” to Trash — Undo", or why a trash action failed. Opaque background: a
    /// translucent material over the list misrenders on the macOS beta.
    @ViewBuilder private var trashNotice: some View {
        if let receipt = model.lastTrashed {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                Text("Moved “\(NotesModel.noteTitle(ofPath: receipt.originalPath))” to Trash")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Undo") {
                    Task {
                        await model.undoLastTrash()
                        await indexService.rescan()
                    }
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.headerBackground, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        } else if let failure = model.trashFailure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
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
            .confirmationDialog(
                createLinkCandidate.map { "Create “\(NotesModel.sanitizeFileName($0.title))”?" } ?? "Create Note?",
                isPresented: Binding(
                    get: { createLinkCandidate != nil },
                    set: {
                        if !$0 {
                            createLinkCandidate = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: createLinkCandidate
            ) { link in
                Button("Create Note") {
                    model.createNote(titled: link.title, in: selectedNoteFolderPath)
                }
            } message: { _ in
                Text(
                    selectedNoteFolderPath.isEmpty
                        ? "No note has this name yet. It will be created at the top of the vault."
                        : "No note has this name yet. It will be created in “\(selectedNoteFolderPath)”."
                )
            }
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "note.text",
                description: Text("Choose a note from the list, or create one.")
            )
        }
    }

    #if os(macOS)
        /// WYSIWYG affordances over plain markdown: every button writes syntax.
        /// macOS: a title row (file name, daily-note arrows, ⋯ overflow) over one
        /// tool row (format cluster left, mode picker right), both on one opaque
        /// tone (spec ux-phase2/04). Nothing here may use `.safeAreaInset`, a
        /// material or a window toolbar — all let editor text slide underneath
        /// a translucent strip on the beta (user report ×3).
        private var editorHeader: some View {
            VStack(spacing: 0) {
                titleRow
                toolRow
            }
            .background(Color.headerBackground)
        }

        private var titleRow: some View {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Double-click opens Rename (spec ux-phase2/04 + 05).
                    .onTapGesture(count: 2) { openRenameFromTitleRow() }
                Spacer(minLength: 8)
                if let day = model.openDailyNoteDate {
                    HStack(spacing: 4) {
                        actionIcon("chevron.backward", "Previous day") {
                            stepDailyNote(from: day, by: -1)
                        }
                        actionIcon("chevron.forward", "Next day") {
                            stepDailyNote(from: day, by: 1)
                        }
                    }
                }
                overflowMenu
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }

        private var toolRow: some View {
            HStack(spacing: 0) {
                formatBar
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Outside the scrolling format bar on purpose: the mode picker
                // must never scroll out of reach.
                modePicker
                    .padding(.leading, 8)
                    .padding(.trailing, 16)
            }
        }

        /// Double-clicking the title opens the Rename sheet (spec 05), the same
        /// route as the ⋯ menu's Rename Note… and File ▸ Rename Note… (⌥⌘R).
        private func openRenameFromTitleRow() {
            performMenuCommand(.renameNote)
        }

        /// Everything the old icon strip held that is not a format button,
        /// built from the shared `ShellCommand` table so titles, icons and
        /// availability match the menu bar. No `.keyboardShortcut` here:
        /// shortcuts belong to the menu bar (a second owner would double-fire).
        private var overflowMenu: some View {
            let aiRunning = aiStatus?.hasSuffix("…") == true
            let isProject = model.selectedID.map(indexService.isProject) ?? false
            return Menu {
                overflowItem(.renameNote)
                overflowItem(.proofread)
                overflowItem(.summarize, disabled: aiRunning)
                overflowItem(.extractActions, disabled: aiRunning)
                if let aiStatus {
                    Divider()
                    Text(aiStatus)
                }
                Divider()
                overflowItem(
                    .lockNote,
                    title: model.selectedIsLockable ? "Remove Lock" : "Lock Note",
                    icon: model.selectedIsLockable ? "lock.open" : "lock"
                )
                overflowItem(
                    .toggleProject,
                    title: isProject ? "Remove Project Flag" : "Make Project"
                )
                Divider()
                overflowToggle(.focusMode, isOn: focusMode)
                overflowToggle(.inspector, isOn: showInspector)
                overflowItem(.linkGraph)
                Divider()
                overflowItem(.moveToTrash)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Note actions: proofread, summarize, lock, project, focus mode, inspector, graph, trash")
        }

        private func overflowItem(
            _ command: ShellCommand, title: String? = nil, icon: String? = nil, disabled: Bool = false
        ) -> some View {
            Button(title ?? command.title, systemImage: icon ?? command.systemImage) {
                performMenuCommand(command)
            }
            .disabled(disabled || !command.isAvailable(commands))
        }

        private func overflowToggle(_ command: ShellCommand, isOn: Bool) -> some View {
            Toggle(command.title, isOn: Binding(get: { isOn }, set: { _ in performMenuCommand(command) }))
                .disabled(!command.isAvailable(commands))
        }
    #else
        /// WYSIWYG affordances over plain markdown: every button writes syntax.
        /// One opaque in-content row above the editor: scrolling formatting
        /// controls on the left, fixed note actions on the right. Nothing here
        /// may use `.safeAreaInset` or a window toolbar — both let editor text
        /// slide underneath a translucent strip on the beta (user report ×3).
        private var editorHeader: some View {
            HStack(spacing: 0) {
                formatBar
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 18)
                // Outside the scrolling format bar on purpose: the mode picker
                // must never scroll out of reach.
                modePicker
                    .padding(.horizontal, 8)
                Divider().frame(height: 18)
                noteActionBar
            }
            .background(Color.headerBackground)
        }
    #endif

    /// Source / Live / Reading. Replaces the old single eye/code toggle;
    /// ⌘E cycles it, ⌘/ still flips Source↔Live. macOS shows text labels
    /// (spec ux-phase2/04); iOS keeps the icon segments.
    private var modePicker: some View {
        Picker("Editor mode", selection: modeBinding) {
            ForEach(EditorMode.allCases, id: \.self) { mode in
                #if os(macOS)
                    Text(mode.shortTitle)
                        .help(mode.title)
                        .tag(mode)
                #else
                    Image(systemName: mode.symbol)
                        .help(mode.title)
                        .tag(mode)
                #endif
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #if os(macOS)
            .frame(width: 220)
        #else
            .frame(width: 108)
        #endif
            .help("Source / Live Preview / Reading — ⌘E cycles, ⌘/ toggles Source and Live")
    }

    /// Daily-note ◀ ▶: opens the day before/after `day`.
    private func stepDailyNote(from day: Date, by days: Int) {
        model.openDailyNote(
            for: Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
        )
    }

    #if !os(macOS)
        /// Note-level actions, formerly the detail pane's `.toolbar` items. iOS
        /// only now: macOS moved them into the title row and its ⋯ menu.
        private var noteActionBar: some View {
            HStack(spacing: 4) {
                if let day = model.openDailyNoteDate {
                    actionIcon("chevron.backward", "Previous day") {
                        stepDailyNote(from: day, by: -1)
                    }
                    actionIcon("chevron.forward", "Next day") {
                        stepDailyNote(from: day, by: 1)
                    }
                }
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
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .disabled(aiStatus?.hasSuffix("…") == true)
                .help("Summarize the note or extract its action items")
                // Editing modes only: Reading has no MarkdownEditor mounted, so
                // nothing would consume the Apply command (critic-caught).
                if model.selectedID != nil, !model.lockedPlaceholder, editorMode != .reading {
                    actionIcon(
                        "text.badge.checkmark",
                        languageToolConfigured
                            ? "Proofread with LanguageTool (⇧⌘P)"
                            : "Proofread — configure a LanguageTool URL in Settings › AI & Import"
                    ) {
                        runProofread()
                    }
                    .disabled(!languageToolConfigured)
                }
                if model.selectedID != nil, !model.lockedPlaceholder {
                    actionIcon(
                        model.selectedIsLockable ? "lock.open" : "lock",
                        model.selectedIsLockable
                            ? "Decrypt this note back to plain markdown"
                            : "Encrypt this note with a passphrase (unrecoverable if forgotten)"
                    ) {
                        toggleLock()
                    }
                }
                if let id = model.selectedID {
                    let isProject = indexService.isProject(id)
                    actionIcon(
                        "calendar.day.timeline.left",
                        isProject
                            ? "This note is a project — click to remove the project flag"
                            : "Turn this note into a project (adds project: true frontmatter)"
                    ) {
                        toggleProjectFlag()
                    }
                }
                actionIcon("point.3.connected.trianglepath.dotted", "Link graph of your vault") {
                    showingGraph = true
                }
                actionIcon(
                    focusMode ? "circle.circle.fill" : "circle.circle",
                    focusMode ? "Focus mode on — dims other paragraphs" : "Focus mode"
                ) {
                    focusMode.toggle()
                }
                actionIcon("sidebar.right", "Outline, backlinks & mentions (⌥⌘0)") {
                    showInspector.toggle()
                }
            }
            .padding(.trailing, 8)
        }
    #endif

    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // Reading mode has nothing to format, so the whole cluster
                // goes away; the mode picker (and, on iOS, the note-action
                // cluster) stay put.
                if editorMode.isEditing {
                    formattingControls
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        #if os(macOS)
        // One tone with the title row (no material), and a fixed row height
        // so switching to Reading, which empties the cluster, does not jump.
        .frame(height: 32)
        #else
        .background(.bar)
        #endif
    }

    @ViewBuilder private var formattingControls: some View {
        Menu {
            headingMenuItem("Title", level: 1)
            headingMenuItem("Heading", level: 2)
            headingMenuItem("Subheading", level: 3)
            Divider()
            headingMenuItem("Body", level: 0)
        } label: {
            if selectionContext.headingLevel > 0 {
                Text("H\(selectionContext.headingLevel)")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 22)
            } else {
                Image(systemName: "textformat.size")
                    .frame(width: 26, height: 22)
            }
        }
        .menuIndicator(.hidden)
        .help("Text style")
        Divider().frame(height: 16)
        formatButton(
            "bold", "Bold (⌘B)", .bold,
            isActive: selectionContext.bold, dimmed: selectionContext.inCodeBlock
        )
        formatButton(
            "italic", "Italic (⌘⇧I)", .italic,
            isActive: selectionContext.italic, dimmed: selectionContext.inCodeBlock
        )
        formatButton(
            "strikethrough", "Strikethrough", .strikethrough,
            isActive: selectionContext.strikethrough, dimmed: selectionContext.inCodeBlock
        )
        // ⌥⌘C, not ⌘E: ⌘E cycles the three view modes now.
        formatButton(
            "chevron.left.forwardslash.chevron.right", "Code (⌥⌘C)", .code,
            isActive: selectionContext.code, dimmed: selectionContext.inCodeBlock
        )
        Divider().frame(height: 16)
        formatButton(
            "list.bullet", "Bullet list", .bulletList, isActive: selectionContext.inList
        )
        formatButton(
            "list.number", "Numbered list", .numberedList, isActive: selectionContext.inList
        )
        formatButton(
            "checklist", "To-do (⌘⇧T)", .todoList, isActive: selectionContext.inList
        )
        formatButton(
            "quote.opening", "Quote", .quote, isActive: selectionContext.inQuote
        )
        Divider().frame(height: 16)
        linkButton
        Divider().frame(height: 16)
        Menu {
            Button("Table", systemImage: "tablecells") {
                sendEditorCommand(.insertTable)
            }
            Button("Image…", systemImage: "photo") {
                showingImagePicker = true
            }
            Button("Horizontal Rule", systemImage: "minus") {
                sendEditorCommand(.insertRule)
            }
            // Table structure: every item is a no-op when the
            // cursor is not in a table, so none of them disable.
            Section("Table") {
                Button("Add Row Below") {
                    editorCommand = EditorCommandRequest(.tableInsertRow)
                }
                Button("Add Column After") {
                    editorCommand = EditorCommandRequest(.tableInsertColumn)
                }
                Button("Delete Row") {
                    editorCommand = EditorCommandRequest(.tableDeleteRow)
                }
                Button("Delete Column") {
                    editorCommand = EditorCommandRequest(.tableDeleteColumn)
                }
                Button("Align Table") {
                    editorCommand = EditorCommandRequest(.tableAlign)
                }
            }
        } label: {
            Image(systemName: "plus.square")
                .frame(width: 26, height: 22)
        }
        .menuIndicator(.hidden)
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
    }

    private func formatButton(
        _ icon: String, _ help: String, _ command: ShellCommand,
        isActive: Bool = false, dimmed: Bool = false
    ) -> some View {
        Button {
            sendEditorCommand(command)
        } label: {
            Image(systemName: icon)
                .frame(width: 26, height: 22)
        }
        .help(help)
        .background(
            isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: Capsule()
        )
        // Markdown syntax is inert inside a code block — wrap buttons stay
        // visible (so the bar doesn't jump around) but read as disabled.
        .opacity(dimmed ? 0.35 : 1)
        .disabled(dimmed)
    }

    private func headingMenuItem(_ title: String, level: Int) -> some View {
        Button {
            editorCommand = EditorCommandRequest(.setHeading(level))
        } label: {
            HStack {
                Text(title)
                if selectionContext.headingLevel == level {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// ⇧⌘K: caret in an existing link opens an edit popover pre-filled with
    /// its text/destination; otherwise falls through to the insert command
    /// (placeholder text + URL, cursor on the URL) as before.
    private var linkButton: some View {
        Button {
            linkAction()
        } label: {
            Image(systemName: "link")
                .frame(width: 26, height: 22)
        }
        .help("Link (⇧⌘K)")
        // A sheet, not .popover: the format bar lives in a safeAreaInset,
        // and popovers anchored inside inset bars are in the same beta
        // bridge family as the toolbar traps — sheets are the pattern this
        // app has already proven (palette, lock/unlock).
        .sheet(isPresented: $showingLinkPopover) { linkEditPopover }
    }

    private var linkEditPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Link").font(.headline)
            TextField("Text", text: $linkPopoverText)
                .textFieldStyle(.roundedBorder)
            TextField("URL", text: $linkPopoverURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Remove Link", role: .destructive) {
                    if let range = linkEditRange {
                        editorCommand = EditorCommandRequest(
                            .removeLink(range: range, expected: linkEditSource, text: linkPopoverText)
                        )
                    }
                    showingLinkPopover = false
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingLinkPopover = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let range = linkEditRange {
                        editorCommand = EditorCommandRequest(
                            .editLink(
                                range: range, expected: linkEditSource,
                                text: linkPopoverText, url: linkPopoverURL
                            )
                        )
                    }
                    showingLinkPopover = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(linkPopoverText.isEmpty || linkPopoverURL.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    /// The display text between `[` and `](` in a link's full markdown
    /// span — the range/destination come from SelectionContext, which
    /// doesn't carry the label itself.
    private func linkLabel(range: NSRange, in text: String) -> String {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return "" }
        let full = ns.substring(with: range)
        guard full.hasPrefix("["), let closeBracket = full.range(of: "](") else { return full }
        return String(full[full.index(after: full.startIndex) ..< closeBracket.lowerBound])
    }

    /// Vault-relative image sources resolve against the note's folder (the
    /// same base the thumbnail itself was drawn against); remote URLs open
    /// as URLs. No-op on iOS this pass.
    private func openAttachment(_ source: String) {
        #if os(macOS)
            if let url = ImageThumbnails.resolveLocalURL(source, base: selectedNoteFolder) {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: source), let scheme = url.scheme,
                      scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        #endif
    }

    /// The editor's paste/drop image importer: copies each drop into the
    /// vault's Attachments/ folder via NotesModel and returns markdown-ready
    /// paths, index-aligned with `drops` (empty string = that one failed —
    /// see RichPaste.AttachmentDrop's doc comment).
    private func importPastedAttachments(_ drops: [AttachmentDrop]) async -> [String] {
        var paths: [String] = []
        for drop in drops {
            let path: String? = switch drop.source {
            case let .fileURL(url):
                await model.attachImage(from: url)
            case let .data(data):
                await model.attachImage(data: data, suggestedName: drop.suggestedName)
            }
            paths.append(path ?? "")
        }
        if paths.allSatisfy(\.isEmpty) {
            importStatus = "Image attach failed"
        }
        return paths
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
                        .help("Close tab")
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

    /// The editor's text-container cap on macOS (spec ux-phase2/04 asks for
    /// Reading mode's 780 pt column). Reading's 780 pt frame holds 24 pt of
    /// padding each side, while editor text sits 5 pt inside its container
    /// (line-fragment padding), so 780 - 2*24 + 2*5 puts the text edges of
    /// both modes in the same place and the switch does not shift the page.
    private static let editorColumnWidth: CGFloat = 742

    @ViewBuilder private var editorPane: some View {
        if model.lockedPlaceholder {
            ContentUnavailableView {
                Label("Locked Note", systemImage: "lock.doc")
            } description: {
                Text("This note is encrypted. Its contents sync as ciphertext only.")
            } actions: {
                Button("Unlock…") {
                    lockPassphrase = ""
                    lockError = nil
                    showingUnlockSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .sheet(isPresented: $showingUnlockSheet) { unlockSheet }
        } else if true {
            // In-content bar over an opaque background, NOT .safeAreaInset:
            // editor content scrolled visibly through the translucent inset
            // bar (user-reported — same beta family as the Meetings header;
            // this is that view's proven layout).
            VStack(spacing: 0) {
                editorHeader
                Divider()
                // Reading mode swaps the text view for the renderer INSIDE
                // this same layout — the in-content header and the hidden
                // window toolbar below stay exactly as they were.
                if editorMode == .reading {
                    ReadingView(
                        source: model.noteText,
                        style: readingStyle,
                        imageBase: selectedNoteFolder,
                        scrollToLine: $readingScrollLine,
                        onToggleTask: { toggleReadingTask(line: $0) },
                        onOpenNote: { openWikilink(raw: $0) },
                        onTopLineChanged: { readingPosition.topLine = $0 }
                    )
                } else {
                    MarkdownEditor(
                        text: Binding(
                            get: { model.noteText },
                            set: { model.noteText = $0; model.textChanged() }
                        ),
                        scrollTarget: $scrollTarget,
                        command: $editorCommand,
                        theme: editorTheme,
                        livePreview: editorMode == .live,
                        focusMode: focusMode,
                        imageBase: selectedNoteFolder,
                        tagCandidates: allTags.map(\.tag),
                        linkCandidates: model.notes.map(noteTitle),
                        mentionCandidates: indexService.allAssignees(),
                        findSignal: findSignal,
                        importAttachments: importPastedAttachments,
                        spellChecking: proofSpelling,
                        grammarChecking: proofGrammar,
                        autocorrect: proofAutocorrect,
                        onSelectionContext: { selectionContext = $0 },
                        onOpenAttachment: { openAttachment($0) },
                        onOpenWikilink: { openWikilink($0) },
                        // macOS centres the text in a capped column; iOS ignores
                        // it this pass.
                        maxTextWidth: Self.editorColumnWidth
                    )
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(statsChip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
            }
            // The detail pane's .toolbar/.navigationTitle render as a
            // translucent strip OVER the top of the content under the beta
            // toolbar bridge (user report ×3: Meetings twice, the editor's
            // format bar once). Every note action lives in `editorHeader`
            // instead. The window toolbar is NOT hidden: that hides the
            // whole NSTitlebarContainerView, traffic lights included; the
            // shell's .windowStyle(.hiddenTitleBar) keeps the band clean.
            #if !os(macOS)
            .navigationTitle(selectedTitle)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: - Menu commands

    /// What the menu bar may enable right now. Written only when a value
    /// changes (`ShellCommandBus.publish`), because each write re-renders
    /// the menu.
    private func publishCommandState() {
        // Also "this Notes view is mounted": after a vault switch the OLD view's onDisappear
        // can land after the NEW view's appear, so the newest view re-asserts it here.
        commands.publish(\.notesTabVisible, true)
        let open = model.selectedID != nil && !model.lockedPlaceholder
        commands.publish(\.hasOpenNote, open)
        commands.publish(\.isEditing, open && editorMode.isEditing)
        commands.publish(\.editorMode, editorMode)
        commands.publish(\.languageToolConfigured, languageToolConfigured)
        commands.publish(\.selectedIsLockable, model.selectedIsLockable)
        commands.publish(\.selectedIsProject, model.selectedID.map(indexService.isProject) ?? false)
        commands.publish(\.inspectorVisible, showInspector)
    }

    /// The Notes-tab half of the command bus (`AppShell` takes `.shell`).
    /// Each case runs the same code as the button it mirrors.
    private func performMenuCommand(_ command: ShellCommand) {
        switch command {
        case .findInNote: findSignal += 1
        case .nextMode: setMode(editorMode.next)
        case .toggleSourceLive: setMode(editorMode == .source ? .live : .source)
        case .modeSource: setMode(.source)
        case .modeLive: setMode(.live)
        case .modeReading: setMode(.reading)
        case .zoomIn: zoomActiveMode(by: 1)
        case .zoomOut: zoomActiveMode(by: -1)
        case .actualSize: resetActiveModeZoom()
        case .focusMode: focusMode.toggle()
        case .inspector: showInspector.toggle()
        case .link: linkAction()
        case .insertImage: showingImagePicker = true
        case .proofread: runProofread()
        case .lockNote: toggleLock()
        case .toggleProject: toggleProjectFlag()
        case .summarize: runAI(summarize: true)
        case .extractActions: runAI(summarize: false)
        case .linkGraph: showingGraph = true
        case .moveToTrash: trashCandidate = model.selectedID.flatMap { model.notesById[$0] }
        case .renameNote:
            // Not for the locked placeholder (`hasOpenNote` is false there, so the menu is off
            // too); the context menu can still rename a locked note's FILE.
            guard !model.lockedPlaceholder else { return }
            renameCandidate = model.selectedID.flatMap { model.notesById[$0] }
        default: sendEditorCommand(command)
        }
    }

    /// The Format menu and the format bar both end here.
    private func sendEditorCommand(_ command: ShellCommand) {
        guard let editorCommand = command.editorCommand else { return }
        self.editorCommand = EditorCommandRequest(editorCommand)
    }

    /// ⇧⌘K: caret in an existing link opens an edit popover pre-filled with
    /// its text/destination; otherwise falls through to the insert command
    /// (placeholder text + URL, cursor on the URL).
    private func linkAction() {
        if let link = selectionContext.link,
           NSMaxRange(link.range) <= (model.noteText as NSString).length {
            linkEditRange = link.range
            linkEditSource = (model.noteText as NSString).substring(with: link.range)
            linkPopoverText = linkLabel(range: link.range, in: model.noteText)
            linkPopoverURL = link.destination
            showingLinkPopover = true
        } else {
            editorCommand = EditorCommandRequest(.link)
        }
    }

    /// The lock icon / Note ▸ Lock Note: encrypt, or decrypt back to markdown.
    private func toggleLock() {
        if model.selectedIsLockable {
            Task { await model.removeLockFromSelected() }
        } else {
            lockPassphrase = ""
            lockConfirm = ""
            lockError = nil
            showingLockSheet = true
        }
    }

    /// The project icon / Note ▸ Make Project: flips `project: true` frontmatter.
    private func toggleProjectFlag() {
        guard let id = model.selectedID else { return }
        let isProject = indexService.isProject(id)
        Task { await indexService.setNoteFlag(id, key: "project", value: !isProject) }
    }

    // MARK: - View mode

    /// The picker writes through `setMode` so every switch carries the
    /// scroll position with it.
    private var modeBinding: Binding<EditorMode> {
        Binding(get: { editorMode }, set: { setMode($0) })
    }

    /// Switching modes keeps the reader's place. Source↔Live share one text
    /// view, so there is nothing to do there; the editor↔Reading crossings
    /// hand each other a FILE line number.
    private func setMode(_ mode: EditorMode) {
        guard mode != editorMode else { return }
        if mode == .reading {
            readingScrollLine = editorCaretLine() ?? 0
            // A command nobody consumes must not fire when the editor
            // mounts again later.
            editorCommand = nil
        } else if editorMode == .reading {
            // Caret to the start of the block Reading had at the top — the
            // editor's scrollTarget already places the caret and scrolls.
            let offset = ReadingSourceLines(model.noteText)
                .utf16Offset(ofLine: readingPosition.topLine)
            scrollTarget = NSRange(location: offset, length: 0)
        }
        editorMode = mode
    }

    /// The caret's 0-based FILE line, read off the editor's text view.
    /// EditorKit publishes formatting state but not the caret offset, and it
    /// publishes only when that state CHANGES — so the switch has to ask the
    /// view itself for the caret as it is right now. Found by walking the
    /// window rather than by first responder, because clicking the mode
    /// picker moves focus off the editor before this runs; the text
    /// comparison is what proves it's OUR editor and not a field editor.
    private func editorCaretLine() -> Int? {
        #if os(macOS)
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  let textView = Self.editorTextView(in: window.contentView, text: model.noteText)
            else { return nil }
            return ReadingSourceLines(model.noteText)
                .line(forUTF16Offset: textView.selectedRange().location)
        #else
            return nil
        #endif
    }

    #if os(macOS)
        private static func editorTextView(in view: NSView?, text: String) -> NSTextView? {
            guard let view else { return nil }
            if let textView = view as? NSTextView, textView.string == text {
                return textView
            }
            for subview in view.subviews {
                if let found = editorTextView(in: subview, text: text) {
                    return found
                }
            }
            return nil
        }
    #endif

    /// MarkdownEditor renders Source and Live Preview only (Reading swaps
    /// in ReadingView) — each uses its own mode's stored design/size.
    private var editorTheme: MarkdownTheme {
        let (design, size) = editorMode == .source
            ? (sourceFontDesign, sourceFontSize)
            : (editorFontDesign, editorFontSize)
        return .default.customized(
            baseFontSize: CGFloat(size),
            fontDesign: design,
            findHighlight: findHighlightColor,
            headingScale: CGFloat(headingScalePercent / 100)
        )
    }

    /// ReadingKit can't see EditorKit's theme or the To-Do tab's chips, so
    /// the app hands it both — one place keeps Reading mode's colors equal
    /// to the editor's and to the task list's.
    private var readingStyle: ReadingStyle {
        ReadingStyle(
            baseFontSize: CGFloat(readingFontSize),
            fontDesign: Self.fontDesign(readingFontDesign),
            headingScale: CGFloat(headingScalePercent / 100),
            tagColor: { TaskChipStyle.labelColor($0) },
            kindColor: { TaskChipStyle.kindColor($0) },
            priorityColor: { TaskChipStyle.priorityColor($0) }
        )
    }

    // MARK: - Zoom (⌘= / ⌘− / ⌘0)

    /// Hardware-keyboard zoom targets whichever mode is on screen right
    /// now — Source and Live have independent sizes, so this reads/writes
    /// the active mode's stored key, not a single shared one.
    private func zoomActiveMode(by delta: CGFloat) {
        let clamped = EditorFontPreferences.clamp(activeModeFontSize + delta)
        setActiveModeFontSize(clamped)
    }

    private func resetActiveModeZoom() {
        setActiveModeFontSize(EditorFontPreferences.defaultSize)
    }

    private var activeModeFontSize: CGFloat {
        switch editorMode {
        case .source: CGFloat(sourceFontSize)
        case .live: CGFloat(editorFontSize)
        case .reading: CGFloat(readingFontSize)
        }
    }

    private func setActiveModeFontSize(_ size: CGFloat) {
        switch editorMode {
        case .source: sourceFontSize = Double(size)
        case .live: editorFontSize = Double(size)
        case .reading: readingFontSize = Double(size)
        }
    }

    private static func fontDesign(_ name: String) -> Font.Design {
        switch name {
        case "serif": .serif
        case "rounded": .rounded
        case "mono": .monospaced
        default: .default
        }
    }

    /// Reading mode's checkbox takes the SAME outbound route the To-Do tab
    /// takes: find the index row for (note, line) and let the service
    /// rewrite the source markdown line under file coordination.
    /// `model.noteText` is never poked directly — the reload hook re-renders
    /// Reading mode from the rewritten file.
    private func toggleReadingTask(line: Int) {
        guard let noteId = model.selectedID,
              let task = indexService.tasks(inNote: noteId).first(where: { $0.line == line })
        else { return }
        // The index can trail the editor by an autosave + reindex. If the
        // line under this checkbox is not the task the index thinks it is,
        // do nothing rather than flip a neighbour (critic-caught race).
        let lines = splitLines(model.noteText)
        guard line < lines.count,
              strippingCarriageReturn(lines[line]).trimmingCharacters(in: .newlines)
              == task.rawLine.trimmingCharacters(in: .newlines)
        else { return }
        Task { await indexService.toggle(task) }
    }

    /// Every wikilink click (⌘-click in Source/Live, a tap in Reading) ends here and resolves
    /// through the one resolver (`WikilinkSyntax.resolve`, spec ux-phase2/05-06): path first,
    /// then title, preferring the source note's folder. `#Heading` / `#^block` anchors land on
    /// their line; `[[#Heading]]` jumps within this note; an unknown title offers to create it.
    private func openWikilink(_ link: Wikilink) {
        let anchor: (heading: String?, blockId: String?)? =
            link.heading != nil || link.blockId != nil ? (link.heading, link.blockId) : nil
        let pool = model.notes.map { (id: $0.id, title: noteTitle($0)) }
        if let id = WikilinkSyntax.resolve(link, among: pool, from: model.selectedID) {
            if id == model.selectedID {
                jumpToAnchorInOpenNote(anchor)
            } else {
                model.openNote(id, jumpToAnchor: anchor)
            }
        } else if link.target.isEmpty {
            jumpToAnchorInOpenNote(anchor)
        } else {
            createLinkCandidate = link
        }
    }

    /// Reading mode hands over the raw text between the brackets (`Plan|alias`).
    private func openWikilink(raw: String) {
        guard let link = WikilinkSyntax.links(in: "[[\(raw)]]").first else { return }
        openWikilink(link)
    }

    private func jumpToAnchorInOpenNote(_ anchor: (heading: String?, blockId: String?)?) {
        guard let anchor,
              let line = WikilinkSyntax.anchorLine(heading: anchor.heading, blockId: anchor.blockId, in: model.noteText)
        else { return }
        jump(toLine: line)
    }

    /// Caret (Source/Live) or scroll (Reading) to a 0-based file line.
    private func jump(toLine line: Int) {
        if editorMode == .reading {
            readingScrollLine = line
            return
        }
        let lines = splitLines(model.noteText)
        guard line < lines.count else { return }
        let offset = lines.prefix(line).reduce(0) { $0 + $1.utf16.count + 1 }
        scrollTarget = NSRange(location: offset, length: 0)
    }

    /// The open note's folder as a vault-relative path ("" = root): where "Create Note" puts
    /// a note for an unresolved link.
    private var selectedNoteFolderPath: String {
        guard let id = model.selectedID, id.contains("/") else { return "" }
        return (id as NSString).deletingLastPathComponent
    }

    // MARK: - Rename (spec ux-phase2/05)

    /// The sheet's Rename: the model renames the file (heading, move, retarget, self links),
    /// then the service rewrites the other notes' links. Returns the message the sheet shows
    /// when the rename itself was refused or failed; nil once the file is renamed (link
    /// failures go to the Try Again alert, not the sheet).
    private func performRename(_ note: VaultItem, to name: String) async -> String? {
        // The listing BEFORE the move: links resolve against it, so one that points at a
        // different note with the same title is left alone.
        let pool = model.notes.map { (id: $0.id, title: noteTitle($0)) }
        switch await model.rename(note, to: name) {
        case let .failure(error):
            return NotesModel.message(for: error, base: NotesModel.renameBaseName(name))
        case let .success(receipt):
            guard receipt.oldId != receipt.newId else { return nil }
            // The file is renamed and everything keyed by its id is retargeted, so the sheet
            // can close now. Rewriting the other notes' links re-reads the vault and can take
            // a while on a phone; it runs behind the sheet (failures surface in the Try Again
            // alert) and Undo waits for it.
            let previous = linkRewriteTask
            linkRewriteTask = Task {
                await previous?.value
                await rewriteInboundLinks(for: receipt, pool: pool)
            }
            return nil
        }
    }

    /// Step 8: inbound links, then a rescan so the renamed note is indexed under its new id
    /// and the old row is pruned. Undo and Try Again come through here too.
    private func rewriteInboundLinks(
        for receipt: NotesModel.RenameReceipt, pool: [(id: String, title: String)], only: Set<String>? = nil
    ) async {
        let report = await indexService.rewriteInboundLinks(
            oldTitle: receipt.oldTitle, newTitle: receipt.newTitle, renamedId: receipt.oldId,
            among: pool, skipping: [receipt.oldId, receipt.newId], only: only
        )
        await indexService.rescan()
        if !report.failed.isEmpty {
            linkRetry = LinkRetry(receipt: receipt, pool: pool, failed: report.failed)
        }
    }

    private func undoRename() {
        Task {
            // Undo must not race the forward rewrite of the other notes' links.
            await linkRewriteTask?.value
            let pool = model.notes.map { (id: $0.id, title: noteTitle($0)) }
            if let reverse = await model.undoLastRename() {
                await rewriteInboundLinks(for: reverse, pool: pool)
            } else {
                await indexService.rescan()
            }
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
            // migrateFromDefaults, not read(): a URL seeded into defaults
            // reaches the Keychain on first use HERE, not only once Settings
            // has been opened.
            let ollamaURL = KeychainStore.migrateFromDefaults(key: "ollamaURL", account: "ollamaURL")
            if let url = ServerURL.normalize(ollamaURL) {
                let model = UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3"
                providers.append(OllamaProvider(baseURL: url, model: model.isEmpty ? "qwen3" : model))
            }
            #if canImport(FoundationModels)
                // AIRouter walks providers in order and skips any whose
                // isAvailable() fails, so "prefer Ollama" still falls back
                // to on-device when the homelab is unreachable.
                if aiPreferOllama {
                    providers.append(FoundationModelsProvider())
                } else {
                    providers.insert(FoundationModelsProvider(), at: 0)
                }
            #endif
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

    // MARK: - Proofread (LanguageTool)

    /// Keychain-backed, ThisDeviceOnly — same policy as `ollamaURL`.
    /// Read-only here; Settings › AI & Import owns writing it.
    private func configuredLanguageToolURL() -> URL? {
        guard let raw = KeychainStore.read(account: "languageToolURL") else { return nil }
        return ServerURL.normalize(raw)
    }

    /// Memoized for 2 s: the action bar re-evaluates on every keystroke and
    /// a Keychain read per keystroke is real work; the short TTL still
    /// picks up a URL saved in Settings almost immediately.
    private var languageToolConfigured: Bool {
        let now = Date()
        if now.timeIntervalSince(languageToolProbe.checkedAt) > 2 {
            languageToolProbe.value = configuredLanguageToolURL() != nil
            languageToolProbe.checkedAt = now
        }
        return languageToolProbe.value
    }

    private final class LanguageToolProbe {
        var value = false
        var checkedAt = Date.distantPast
    }

    @State private var languageToolProbe = LanguageToolProbe()

    #if os(macOS)
        /// "Whole note or the selection when non-empty": the Proofread
        /// command sits outside MarkdownEditor's own binding surface (its
        /// call site belongs to a concurrent change), so this reads the
        /// focused NSTextView's live selection directly — the same
        /// technique Format-panel-style commands use for text outside
        /// their own event chain. iOS has no equivalent hook and always
        /// checks the whole note (iOS panel polish is an explicit
        /// non-goal for this pass).
        private func currentEditorSelection() -> NSRange? {
            guard let responder = NSApp.keyWindow?.firstResponder as? MarkdownTextView else { return nil }
            let range = responder.selectedRange()
            return range.length > 0 ? range : nil
        }
    #endif

    /// The ONE exclusion oracle (EditorKit): code, frontmatter, link
    /// destinations, images, wikilinks, chips, and task-line tokens — the
    /// same spans the system spell checker skips, so LanguageTool never
    /// flags markdown syntax as prose.
    private func proofingExclusionRanges(in text: String) -> [NSRange] {
        ProofingExclusions.ranges(in: text, styled: MarkdownStyler.styleRanges(in: text))
    }

    /// Runs LanguageTool on the whole note, or the selection when it's
    /// non-empty. Never touches `model.noteText` — every accepted
    /// replacement goes through `editorCommand` so undo keeps working.
    private func runProofread() {
        guard model.selectedID != nil, !model.lockedPlaceholder else { return }
        let noteText = model.noteText
        let ns = noteText as NSString
        var scopeRange = NSRange(location: 0, length: ns.length)
        #if os(macOS)
            if let selection = currentEditorSelection(), NSMaxRange(selection) <= ns.length {
                scopeRange = selection
            }
        #endif
        let scopeText = ns.substring(with: scopeRange)
        let scopeOffset = scopeRange.location
        let language = languageToolLanguage

        proofreadRows = []
        ignoredProofreadRuleIds = []
        proofreadState = .running
        showingProofread = true

        proofreadTask?.cancel()
        proofreadTask = Task {
            guard let url = configuredLanguageToolURL() else {
                proofreadState = .error("No LanguageTool URL configured — set one in Settings › AI & Import.")
                return
            }
            guard !scopeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                proofreadState = .noIssues
                return
            }
            let exclusions = proofingExclusionRanges(in: scopeText)
            let provider = LanguageToolProvider(baseURL: url)
            do {
                let matches = try await provider.check(scopeText, excluding: exclusions, language: language)
                guard !Task.isCancelled else { return }
                let scopeNS = scopeText as NSString
                proofreadRows = matches.map { match in
                    let excerpt = scopeNS.substring(with: match.range)
                    let noteRange = NSRange(location: match.range.location + scopeOffset, length: match.range.length)
                    let noteMatch = GrammarMatch(
                        id: match.id, range: noteRange, message: match.message,
                        shortMessage: match.shortMessage, replacements: match.replacements,
                        ruleId: match.ruleId, category: match.category
                    )
                    return ProofreadRow(id: match.id, match: noteMatch, excerpt: excerpt)
                }
                proofreadState = proofreadRows.isEmpty ? .noIssues : .results
            } catch let error as GrammarError {
                guard !Task.isCancelled else { return }
                proofreadState = .error(proofreadErrorMessage(error, url: url))
            } catch {
                guard !Task.isCancelled else { return }
                proofreadState = .error(
                    "LanguageTool unreachable at \(url.absoluteString) — check Settings › AI & Import."
                )
            }
        }
    }

    private func proofreadErrorMessage(_ error: GrammarError, url: URL) -> String {
        switch error {
        case .unreachable:
            "LanguageTool unreachable at \(url.absoluteString) — check Settings › AI & Import."
        case .timeout:
            "LanguageTool timed out at \(url.absoluteString) — check Settings › AI & Import."
        case let .badResponse(detail):
            "LanguageTool returned something unexpected (\(detail)) — check Settings › AI & Import."
        }
    }

    /// Apply goes through the editor command (never `model.noteText`
    /// directly) so undo works. `row.excerpt` — captured when the check
    /// ran, never re-read from the live note — is the `.replaceRange`
    /// guard's `expected`: `editorCommand` is consumed asynchronously by
    /// the editor, so a second Apply clicked before the first has been
    /// applied can't re-derive `expected` from a not-yet-updated
    /// `model.noteText`. Remaining rows' ranges are then shifted by plain
    /// offset arithmetic (`GrammarMatch.shifted`) rather than re-running
    /// the check — instant, and the sheet already has everything it needs
    /// in memory.
    private func applyProofreadMatch(_ row: ProofreadRow, replacement: String) {
        editorCommand = EditorCommandRequest(
            .replaceRange(range: row.match.range, expected: row.excerpt, with: replacement)
        )
        let survivors = GrammarMatch.shifted(
            proofreadRows.map(\.match), afterApplying: row.match, newLength: (replacement as NSString).length
        )
        let excerptById = Dictionary(uniqueKeysWithValues: proofreadRows.map { ($0.id, $0.excerpt) })
        proofreadRows = survivors.map { match in
            ProofreadRow(id: match.id, match: match, excerpt: excerptById[match.id] ?? "")
        }
        if proofreadRows.filter({ !ignoredProofreadRuleIds.contains($0.match.ruleId) }).isEmpty {
            proofreadState = .noIssues
        }
    }

    private func contextSnippet(for range: NSRange, context: Int = 24) -> String {
        let ns = model.noteText as NSString
        guard NSMaxRange(range) <= ns.length else { return "" }
        let start = max(0, range.location - context)
        let end = min(ns.length, NSMaxRange(range) + context)
        let before = ns.substring(with: NSRange(location: start, length: range.location - start))
        let flagged = ns.substring(with: range)
        let after = ns.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        return "…\(before)⟦\(flagged)⟧\(after)…"
            .replacingOccurrences(of: "\n", with: " ")
    }

    private var proofreadSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Proofread", systemImage: "text.badge.checkmark")
                    .font(.headline)
                Spacer()
                Button("Done") { showingProofread = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            Group {
                switch proofreadState {
                case .idle:
                    EmptyView()
                case .running:
                    VStack(spacing: 12) {
                        ProgressView()
                        Button("Cancel") {
                            proofreadTask?.cancel()
                            showingProofread = false
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noIssues:
                    ContentUnavailableView(
                        "No Issues Found", systemImage: "checkmark.circle",
                        description: Text("LanguageTool found nothing to flag in this text.")
                    )
                case let .error(message):
                    ContentUnavailableView {
                        Label("Proofread Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .results:
                    proofreadResultsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheetFrame(width: 460, height: 480)
    }

    private var proofreadResultsList: some View {
        let visible = proofreadRows.filter { !ignoredProofreadRuleIds.contains($0.match.ruleId) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(visible) { row in
                    proofreadRow(row)
                    Divider()
                }
            }
            .padding()
        }
    }

    private func proofreadRow(_ row: ProofreadRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.match.message)
                .font(.callout)
            Text(contextSnippet(for: row.match.range))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !row.match.replacements.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(row.match.replacements.prefix(5), id: \.self) { replacement in
                            Button(replacement) {
                                applyProofreadMatch(row, replacement: replacement)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Ignore") {
                    proofreadRows.removeAll { $0.id == row.id }
                }
                .controlSize(.small)
                Button("Ignore Rule This Session") {
                    ignoredProofreadRuleIds.insert(row.match.ruleId)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The 10 most-used tags — the sidebar shows only these; the browser
    /// sheet carries the long tail (a full dump was unwieldy, user-reported).
    private var topTags: [(tag: String, count: Int)] {
        Array(allTags.sorted { $0.count > $1.count }.prefix(10))
    }

    private func tagChipRow(_ tag: String, count: Int) -> some View {
        HStack {
            Label(tag, systemImage: "number")
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .listRowBackground(
            selectedTag == tag ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .selectionDisabled(true)
        .onTapGesture {
            selectedTag = selectedTag == tag ? nil : tag
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
            if seen.insert(name).inserted {
                names.append(name)
            }
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

    private var favoriteFolders: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(favoriteFoldersData.utf8))) ?? []
    }

    private func toggleFavoriteFolder(_ folder: String) {
        let updated = favoriteFolders.contains(folder)
            ? favoriteFolders.filter { $0 != folder }
            : favoriteFolders + [folder]
        favoriteFoldersData = (try? JSONEncoder().encode(updated))
            .flatMap { String(data: $0, encoding: .utf8) } ?? favoriteFoldersData
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
        let children = model.folders.filter {
            $0.hasPrefix(folder + "/") && !$0.dropFirst(folder.count + 1).contains("/")
        }
        // Daily's year/month folders, like its notes, go newest first.
        return VaultPath.isDailyFolder(folder) ? Array(children.reversed()) : children
    }

    /// Main Vault rows carry the List selection tag; auxiliary-section
    /// copies (Pinned/Recents/Bookmarks) select via their own tap instead —
    /// duplicate tags make selection jump, and an unconditional tap gesture
    /// would swallow the List's selection clicks (user-reported).
    private struct SelectableTag: ViewModifier {
        let id: String?
        let select: (String) -> Void

        func body(content: Content) -> some View {
            if let id {
                content.tag(id)
            } else {
                // selectionDisabled: ForEach rows get IMPLICIT selection
                // tags from their identity, so a copy of a selected note in
                // Favorites/Recents would highlight too (user-reported).
                content
                    .selectionDisabled(true)
                    .onTapGesture { select("") }
            }
        }
    }

    /// Re-lists the vault, asks iCloud to materialize anything stale or
    /// placeholder-only, then reindexes so search/tasks match the files.
    private func refreshVault() async {
        await model.refresh()
        await indexService.rescan()
    }

    private func notes(withIds ids: [String]) -> [VaultItem] {
        ids.compactMap { model.notesById[$0] }
    }

    /// Folder contents come from the model's prebuilt grouping. Filtering
    /// `visibleNotes` here instead re-sorted the whole vault once PER FOLDER
    /// on every render, which is what made the list feel sluggish.
    private func notes(in folder: String) -> [VaultItem] {
        let group = model.notesByFolder[folder] ?? []
        guard searching || selectedTag != nil else {
            // Daily keeps its newest-first name order whatever the global sort is set to: a
            // note's modified date says when it was last edited, not which day it is.
            return noteSortOrder == "modified" && !VaultPath.isDailyFolder(folder)
                ? group.sorted {
                    ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast)
                }
                : group
        }
        let allowed = Set(visibleNotes.map(\.id))
        return group.filter { allowed.contains($0.id) }
    }

    /// selectable: false renders rows as tap-to-open copies — a folder can
    /// appear in Favorites AND the Vault tree, and duplicate List selection
    /// tags make the duplicate group render empty.
    private func folderGroup(
        _ folder: String, selectable: Bool = true, section: String = ""
    ) -> AnyView {
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        // Sections and the vault tree track expansion separately — the same
        // folder can be open in Favorites and closed in the Vault list.
        let key = section + "|" + folder
        return AnyView(
            DisclosureGroup(isExpanded: Binding(
                get: { expandedFolders.contains(key) },
                set: { expanded in
                    if expanded {
                        expandedFolders.insert(key)
                    } else {
                        expandedFolders.remove(key)
                    }
                }
            )) {
                ForEach(notes(in: folder)) { note in
                    noteRow(note, showFolder: false, selectable: selectable, section: section)
                }
                ForEach(subfolders(of: folder), id: \.self) { child in
                    folderGroup(child, selectable: selectable, section: section)
                }
            } label: {
                Label(name, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { ids, _ in
                        var moved = false
                        for id in ids {
                            if let note = model.notes.first(where: { $0.id == id }) {
                                model.move(note, toFolder: folder)
                                moved = true
                            }
                        }
                        return moved
                    }
                    // Folders expand; they are never the List selection
                    // (their implicit tag also highlighted duplicates and
                    // clicking one cleared the open note).
                    .selectionDisabled(true)
                    .onTapGesture {
                        if expandedFolders.contains(key) {
                            expandedFolders.remove(key)
                        } else {
                            expandedFolders.insert(key)
                        }
                    }
                    .contextMenu {
                        Button(
                            favoriteFolders.contains(folder)
                                ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: favoriteFolders.contains(folder) ? "star.slash" : "star"
                        ) {
                            toggleFavoriteFolder(folder)
                        }
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

    private func noteRow(
        _ note: VaultItem, showFolder: Bool, selectable: Bool = true, section: String = ""
    ) -> some View {
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
        // Roomier rows: the default density put adjacent titles close enough
        // that a slightly-off click landed on the neighbour (user-reported).
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .draggable(note.id)
        // ONE context menu only: stacking a second .contextMenu shadows the
        // first entirely (user-reported as missing Favorites/Make Project).
        // Attached BEFORE the tag/tap modifier — order matters on the beta.
        .contextMenu {
            Button(
                favoriteIds.contains(note.id) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: favoriteIds.contains(note.id) ? "star.slash" : "star"
            ) {
                Task {
                    await indexService.setNoteFlag(
                        note.id, key: "favorite", value: !favoriteIds.contains(note.id)
                    )
                }
            }
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
            Menu("Move to Area") {
                ForEach(areas.keys.sorted(), id: \.self) { area in
                    Button(area) {
                        Task {
                            await indexService.setFrontmatterValue(
                                note.id, key: "area", value: area
                            )
                        }
                    }
                }
                if !areas.isEmpty {
                    Divider()
                }
                Button("New Area…") {
                    newAreaName = ""
                    newAreaTarget = note.id
                }
                if areas.values.contains(where: { $0.contains(note.id) }) {
                    Button("Remove from Area", role: .destructive) {
                        Task {
                            await indexService.setFrontmatterValue(
                                note.id, key: "area", value: nil
                            )
                        }
                    }
                }
            }
            Button("Make Project", systemImage: "calendar.day.timeline.left") {
                Task {
                    await indexService.setNoteFlag(note.id, key: "project", value: true)
                }
            }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square") {
                model.duplicate(note)
            }
            Button("Rename…", systemImage: "pencil") {
                renameCandidate = note
            }
            Menu("Move To") {
                Button("Vault Root") { model.move(note, toFolder: "") }
                ForEach(model.folders, id: \.self) { folder in
                    Button(folder) { model.move(note, toFolder: folder) }
                }
            }
            if note.hasUnresolvedConflicts {
                Button("Resolve Conflict…", systemImage: "exclamationmark.icloud") {
                    conflictNote = note
                }
            }
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                trashCandidate = note
            }
        }
        .modifier(SelectableTag(id: selectable ? note.id : nil) { _ in
            #if os(macOS)
                sectionHighlight = section + "|" + note.id
                listSelection = nil
            #else
                // The compact split view opens the note when the list's OWN selection becomes
                // non-nil; selecting only through the model left taps on Recents, Favorites
                // and Areas rows doing nothing on iPhone. No persistent row highlight there.
                sectionHighlight = nil
                listSelection = note.id
            #endif
            model.select(note.id)
        })
        .listRowBackground(
            !selectable && sectionHighlight == section + "|" + note.id
                ? Color.accentColor.opacity(0.22)
                : Color.clear
        )
    }

    /// FTS-ranked results first, semantic (meaning-based) extras after.
    private var visibleNotes: [VaultItem] {
        if let selectedTag, !searching {
            let ids = Set(indexService.tagNoteIds(selectedTag))
            return model.notes.filter { ids.contains($0.id) }
        }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Both orders are prebuilt by the model — sorting here ran on
            // every body pass.
            return noteSortOrder == "modified" ? model.notesByModified : model.notes
        }
        let ranked = indexService.searchNoteIds(searchText)
        let rankedSet = Set(ranked)
        let merged = ranked + semanticIds.filter { !rankedSet.contains($0) }
        return merged.compactMap { model.notesById[$0] }
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

    private var lockSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Lock This Note", systemImage: "lock")
                .font(.headline)
            SecureField("Passphrase", text: $lockPassphrase)
            SecureField("Confirm passphrase", text: $lockConfirm)
            Text(
                "⚠️ There is NO recovery. If you forget this passphrase, the note's contents are permanently lost — Apple and Notetaker cannot decrypt it."
            )
            .font(.caption)
            .foregroundStyle(.orange)
            if let lockError {
                Text(lockError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingLockSheet = false }
                Button("Encrypt Note") {
                    guard lockPassphrase.count >= 6 else {
                        lockError = "Use at least 6 characters."
                        return
                    }
                    guard lockPassphrase == lockConfirm else {
                        lockError = "Passphrases don't match."
                        return
                    }
                    Task {
                        if await model.lockSelected(passphrase: lockPassphrase) {
                            showingLockSheet = false
                        } else {
                            lockError = "Encryption failed."
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .sheetFrame(width: 420)
    }

    private var unlockSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Unlock Note", systemImage: "lock.open")
                .font(.headline)
            SecureField("Passphrase", text: $lockPassphrase)
                .onSubmit { attemptUnlock() }
            if let lockError {
                Text(lockError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingUnlockSheet = false }
                Button("Unlock") { attemptUnlock() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .sheetFrame(width: 380)
    }

    private func attemptUnlock() {
        Task {
            if await model.unlockSelected(passphrase: lockPassphrase) {
                showingUnlockSheet = false
            } else {
                lockError = "Wrong passphrase."
            }
        }
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
            Button {
                conflictNote = note
            } label: {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sync conflict — click to resolve")
            .accessibilityLabel("Resolve sync conflict")
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

/// One row in the Proofread sheet: a `GrammarMatch` (range already in
/// `model.noteText`'s coordinate space) plus the exact source text it
/// pointed at when the check ran. `excerpt` is captured once and never
/// re-read from `model.noteText` — see `applyProofreadMatch`'s doc comment
/// for why that matters across a batch of Applies.
private struct ProofreadRow: Identifiable, Equatable {
    let id: UUID
    let match: GrammarMatch
    let excerpt: String
}

private enum ProofreadState: Equatable {
    case idle
    case running
    case noIssues
    case results
    case error(String)
}

/// Inbound notes whose link rewrite failed after a rename (or its Undo), for Try Again.
private struct LinkRetry {
    let receipt: NotesModel.RenameReceipt
    /// The resolution pool the failed pass used (the listing before that rename).
    let pool: [(id: String, title: String)]
    let failed: [LinkRewriteFailure]
}

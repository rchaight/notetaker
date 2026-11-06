import IndexKit
import SecurityKit
import SwiftUI
#if os(macOS)
    import AppKit
#endif

/// Root shell. macOS: Obsidian-style ribbon + custom top tab bar over
/// always-mounted views (the beta TabView's tab highlight blinked on
/// every keystroke and bounced between tabs — instant, animation-free
/// switching with no view recreation replaces it). iOS keeps the
/// adaptive TabView.
struct AppShell: View {
    let indexService: VaultIndexService
    let notesModel: NotesModel
    let extrasStore: TaskExtrasStore
    /// The menu bar's command bus (owned by `NotetakerApp`, so it survives
    /// the shell being rebuilt on a vault switch).
    let commands: ShellCommandBus
    @State private var selectedTab = AppShell.restoredTab()
    @State private var showingPalette = false
    /// Ribbon → tab signals: incrementing pops the matching sheet.
    @State private var quickAddSignal = 0
    @State private var newProjectSignal = 0
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appLockGrace") private var appLockGrace = 60.0
    @State private var locked = false
    @State private var lastUnlocked: Date?
    @State private var backgroundedAt: Date?
    #if os(macOS)
        @State private var calendarSnapshotPublisher = CalendarSnapshotPublisher()
        @State private var remoteReplicaService = RemoteReplicaService.shared
        @AppStorage("calendarShareWithMCP") private var calendarShareWithMCP = false
    #endif

    private static let tabs: [(id: String, title: String, icon: String)] = [
        ("notes", "Notes", "note.text"),
        ("todo", "To-Do", "checklist"),
        ("projects", "Projects", "calendar.day.timeline.left"),
        ("meetings", "Meetings", "person.3"),
        ("calendar", "Calendar", "calendar"),
        ("tags", "Tags", "number"),
        ("vault", "Vault", "icloud"),
    ]

    private static var visibleTabs: [(id: String, title: String, icon: String)] {
        #if DEBUG
            tabs
        #else
            tabs.filter { $0.id != "vault" }
        #endif
    }

    private var visibleTabs: [(id: String, title: String, icon: String)] {
        Self.visibleTabs
    }

    /// UserDefaults hint for the tab the Mac relaunches on (spec ux-phase2/03).
    private static let selectedTabKey = "ui.selectedTab"

    /// The tab to open on: the saved one on the Mac if it is still a visible
    /// tab (a Release build with a saved "vault" falls back), else Notes.
    /// Read when the state is created rather than in a `.task`, so the shell
    /// never mounts the Notes tab for a frame on its way to another one.
    private static func restoredTab() -> String {
        #if os(macOS)
            if let saved = UserDefaults.standard.string(forKey: selectedTabKey),
               visibleTabs.contains(where: { $0.id == saved }) {
                return saved
            }
        #endif
        return "notes"
    }

    var body: some View {
        shellContent
            .overlay {
                if locked {
                    lockScreen
                }
            }
            .onChange(of: scenePhase) {
                switch scenePhase {
                case .background, .inactive:
                    if backgroundedAt == nil {
                        backgroundedAt = Date()
                    }
                case .active:
                    if AppLockPolicy.shouldLock(
                        enabled: appLockEnabled,
                        lastUnlocked: lastUnlocked,
                        backgroundedAt: backgroundedAt,
                        gracePeriod: appLockGrace
                    ) {
                        locked = true
                    }
                    backgroundedAt = nil
                @unknown default:
                    break
                }
            }
            .onChange(of: commands.requestID) {
                guard let command = commands.pending, command.scope == .shell else { return }
                perform(command)
            }
            .onChange(of: selectedTab) {
                #if os(macOS)
                    UserDefaults.standard.set(selectedTab, forKey: Self.selectedTabKey)
                #endif
            }
            .task(id: appLockEnabled) {
                // Launch lock: enabled + never unlocked this run.
                if appLockEnabled, lastUnlocked == nil {
                    locked = true
                }
            }
            .sheet(isPresented: $showingPalette) {
                CommandPalette(
                    notes: notesModel.notes.map {
                        let components = $0.relativePath.split(separator: "/")
                        return PaletteRanking.Note(
                            id: $0.id,
                            title: URL(fileURLWithPath: $0.relativePath)
                                .deletingPathExtension().lastPathComponent,
                            folder: components.count > 1 ? components.dropLast().joined(separator: "/") : nil
                        )
                    },
                    recents: notesModel.recents,
                    commands: ShellCommand.allCases
                        .filter { $0 != .commandPalette && $0.isAvailable(commands) }
                        .map { ($0, paletteTitle($0)) },
                    searchBodies: { indexService.searchNoteIds($0) },
                    onOpenNote: { id in
                        notesModel.openNote(id, jumpToLine: nil)
                        selectedTab = "notes"
                    },
                    onCommand: { commands.perform($0) },
                    onQuickAdd: { text in Task { await indexService.quickAdd(text) } },
                    isPresented: $showingPalette
                )
            }
            .task {
                // Not left to the Notes tab: the shell can open on another
                // tab, and the palette, Tags and To-Do jumps all need the
                // vault listing. `start()` runs once, whoever calls first.
                await notesModel.start()
            }
            .task {
                indexService.onNoteMutated = { [weak notesModel = notesModel] noteId in
                    notesModel?.reloadIfDisplayed(noteId: noteId)
                }
                indexService.beforeNoteMutation = { [weak notesModel = notesModel] noteId in
                    guard let notesModel, notesModel.selectedID == noteId else { return }
                    await notesModel.flushSave(allowRename: false)
                }
                notesModel.dailySectionsProvider = { [weak indexService = indexService] in
                    indexService?.dailySections() ?? (week: "", continuous: "", horizon: "")
                }
                await indexService.start()
            }
        #if os(macOS)
            .task { calendarSnapshotPublisher.start() }
            .task { remoteReplicaService.start(indexService: indexService) }
            .onChange(of: calendarShareWithMCP) { calendarSnapshotPublisher.settingsChanged() }
            .task {
                // Scene storage restores window frames independently of the
                // saved-state purge — clamp anything the buggy sizing builds
                // persisted beyond the visible screen.
                try? await Task.sleep(for: .milliseconds(400))
                for window in NSApplication.shared.windows where window.isVisible {
                    guard let screen = window.screen ?? NSScreen.main else { continue }
                    let visible = screen.visibleFrame
                    if window.frame.width > visible.width || window.frame.height > visible.height {
                        let size = NSSize(
                            width: min(1150, visible.width - 60),
                            height: min(760, visible.height - 60)
                        )
                        let origin = NSPoint(
                            x: visible.midX - size.width / 2,
                            y: visible.midY - size.height / 2
                        )
                        window.setFrame(NSRect(origin: origin, size: size), display: true)
                    }
                }
            }
        #endif
    }

    /// The `.shell`-scope half of the command bus: everything that works
    /// from any tab (File, Go, the palette). `NotesView` performs the
    /// Notes-tab scopes off the same requests.
    private func perform(_ command: ShellCommand) {
        switch command {
        case .newNote:
            notesModel.createNote()
            selectedTab = "notes"
        case .newTask:
            show("todo") { quickAddSignal += 1 }
        case .newProject:
            show("projects") { newProjectSignal += 1 }
        case .dailyNote:
            notesModel.openDailyNote()
            selectedTab = "notes"
        case .refreshVault:
            Task {
                await notesModel.refresh()
                await indexService.rescan()
            }
        case .goNotes: selectedTab = "notes"
        case .goTodo: selectedTab = "todo"
        case .goProjects: selectedTab = "projects"
        case .goMeetings: selectedTab = "meetings"
        case .goCalendar: selectedTab = "calendar"
        case .goTags: selectedTab = "tags"
        case .goVault: selectedTab = "vault"
        case .commandPalette: showingPalette = true
        case .closeNote:
            #if os(macOS)
                closeNote()
            #endif
        case .closeWindow:
            #if os(macOS)
                if let key = NSApp.keyWindow, !key.isSheet {
                    key.performClose(nil)
                }
            #endif
        default: break
        }
    }

    /// The palette row title for a command. Lock and Project flip with the
    /// open note's state, exactly as the menu bar's items do.
    private func paletteTitle(_ command: ShellCommand) -> String {
        switch command {
        case .lockNote: commands.selectedIsLockable ? "Remove Lock" : command.title
        case .toggleProject: commands.selectedIsProject ? "Remove Project Flag" : command.title
        default: command.title
        }
    }

    /// Switches to `tab`, then bumps a ribbon-style signal. A tab's
    /// `.onChange(of: signal)` ignores the value it is first built with, so
    /// a signal raised in the same turn as the switch never reaches a tab
    /// that was not already on screen; wait for the new tab to mount.
    private func show(_ tab: String, thenSignal signal: @escaping () -> Void) {
        guard selectedTab != tab else {
            signal()
            return
        }
        selectedTab = tab
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            signal()
        }
    }

    #if os(macOS)
        /// ⌘W. In the vault window it closes the open note's tab (selecting
        /// the previous one, or nothing) and never the window; in the Task
        /// window or Settings it closes that window. Only the vault's
        /// WindowGroup uses `.hiddenTitleBar`, which is how it is told apart.
        private func closeNote() {
            guard let key = NSApp.keyWindow, !key.isSheet else { return }
            if key.titleVisibility == .hidden {
                guard selectedTab == "notes", let id = notesModel.selectedID else { return }
                notesModel.closeTab(id)
            } else {
                key.performClose(nil)
            }
        }
    #endif

    @ViewBuilder private var shellContent: some View {
        #if os(macOS)
            HStack(spacing: 0) {
                ribbon
                Divider()
                VStack(spacing: 0) {
                    topTabBar
                    Divider()
                    mountedViews
                }
            }
        #else
            TabView(selection: $selectedTab) {
                Tab("Notes", systemImage: "note.text", value: "notes") {
                    notesTab
                }
                Tab("To-Do", systemImage: "checklist", value: "todo") {
                    todoTab
                }
                Tab("Projects", systemImage: "calendar.day.timeline.left", value: "projects") {
                    projectsTab
                }
                Tab("Meetings", systemImage: "person.3", value: "meetings") {
                    meetingsTab
                }
                Tab("Calendar", systemImage: "calendar", value: "calendar") {
                    calendarTab
                }
                Tab("Tags", systemImage: "number", value: "tags") {
                    tagsTab
                }
                // No Vault tab on iOS: it is a Debug-only container browser (still on the
                // Mac). The phone gets six tabs in every configuration.
            }
            .tabViewStyle(.sidebarAdaptable)
        #endif
    }

    /// Plain switch: exactly ONE view in the hierarchy — mounting all
    /// tabs unions their window toolbars into the min size (scripted
    /// resize check clamped at 1410pt even with toolbarVisibility(.hidden);
    /// the beta does not unregister hidden toolbars). Perceived switch lag
    /// is solved by caching the editor's NSTextView in EditorKit instead.
    @ViewBuilder private var mountedViews: some View {
        switch selectedTab {
        case "todo": todoTab
        case "projects": projectsTab
        case "meetings": meetingsTab
        case "calendar": calendarTab
        case "tags": tagsTab
        #if DEBUG
            case "vault": vaultTab
        #endif
        default: notesTab
        }
    }

    private var meetingsTab: some View {
        MeetingsView(service: indexService, extrasStore: extrasStore) { noteId, line in
            notesModel.openNote(noteId, jumpToLine: line)
            selectedTab = "notes"
        }
    }

    private var calendarTab: some View {
        CalendarView(openDailyNote: { date in
            notesModel.openDailyNote(for: date)
            selectedTab = "notes"
        })
    }

    private var tagsTab: some View {
        TagsView(
            service: indexService,
            model: notesModel,
            openNote: { id in
                notesModel.openNote(id, jumpToLine: nil)
                selectedTab = "notes"
            },
            extrasStore: extrasStore
        )
    }

    private var notesTab: some View {
        NotesView(indexService: indexService, model: notesModel, commands: commands)
    }

    private var todoTab: some View {
        TodoView(
            service: indexService,
            extrasStore: extrasStore,
            quickAddSignal: quickAddSignal
        ) { noteId, line in
            notesModel.openNote(noteId, jumpToLine: line)
            selectedTab = "notes"
        }
    }

    private var projectsTab: some View {
        ProjectsView(
            service: indexService,
            extrasStore: extrasStore,
            newProjectSignal: newProjectSignal
        )
    }

    #if DEBUG
        private var vaultTab: some View {
            NavigationSplitView {
                List {
                    Label("Container Browser", systemImage: "externaldrive")
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                .navigationTitle("Vault")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Rescan", systemImage: "arrow.clockwise") {
                            Task { await indexService.rescan() }
                        }
                        .help("Re-scan the vault and rebuild the index")
                        #if os(macOS)
                            Button("Reveal in Finder", systemImage: "folder") {
                                if let root = indexService.vaultRootURL {
                                    NSWorkspace.shared.open(root)
                                }
                            }
                            .help("Open the vault folder in Finder")
                        #endif
                    }
                }
            } detail: {
                NavigationStack {
                    VaultDebugView()
                        .navigationTitle("Vault")
                }
            }
        }
    #endif

    #if os(macOS)
        private var topTabBar: some View {
            HStack(spacing: 6) {
                ForEach(visibleTabs, id: \.id) { tab in
                    Button {
                        selectedTab = tab.id
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .font(.callout.weight(selectedTab == tab.id ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                selectedTab == tab.id
                                    ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                                in: Capsule()
                            )
                            // The whole capsule is the click target — without
                            // this, the icon-text gap and padding are dead
                            // zones (only rendered pixels hit-test).
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Switch to \(tab.title)")
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }

        /// Obsidian-style quick-action strip.
        private var ribbon: some View {
            VStack(spacing: 16) {
                ribbonButton("square.and.pencil", "New note") {
                    notesModel.createNote()
                    selectedTab = "notes"
                }
                ribbonButton("calendar", "Today's daily note") {
                    notesModel.openDailyNote()
                    selectedTab = "notes"
                }
                ribbonButton("plus.circle", "New task (Quick Add)") {
                    selectedTab = "todo"
                    quickAddSignal += 1
                }
                ribbonButton("calendar.day.timeline.left", "New project") {
                    selectedTab = "projects"
                    newProjectSignal += 1
                }
                ribbonButton("command", "Command palette (⌘K)") {
                    showingPalette = true
                }
                Spacer()
            }
            .padding(.top, 14)
            .frame(width: 40)
            .background(.bar)
        }

        private func ribbonButton(
            _ icon: String, _ help: String, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    #endif
}

extension AppShell {
    private var lockScreen: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Notetaker is locked")
                    .font(.title3.weight(.medium))
                Button("Unlock") {
                    Task { await unlock() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .task { await unlock() }
    }

    private func unlock() async {
        guard await BiometricUnlock.authenticate(reason: "Unlock Notetaker") else { return }
        lastUnlocked = Date()
        locked = false
    }
}

#Preview {
    AppShell(
        indexService: VaultIndexService(),
        notesModel: NotesModel(),
        extrasStore: TaskExtrasStore(),
        commands: ShellCommandBus()
    )
}

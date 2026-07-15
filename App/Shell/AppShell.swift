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
    @State private var indexService = VaultIndexService()
    @State private var notesModel = NotesModel()
    @State private var selectedTab = "notes"
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

    private static let tabs: [(id: String, title: String, icon: String)] = [
        ("notes", "Notes", "note.text"),
        ("todo", "To-Do", "checklist"),
        ("projects", "Projects", "calendar.day.timeline.left"),
        ("tags", "Tags", "number"),
        ("vault", "Vault", "icloud"),
    ]

    private var visibleTabs: [(id: String, title: String, icon: String)] {
        #if DEBUG
            Self.tabs
        #else
            Self.tabs.filter { $0.id != "vault" }
        #endif
    }

    var body: some View {
        shellContent
            .background(
                // Invisible global hotkey for the palette.
                Button("") { showingPalette = true }
                    .keyboardShortcut("k", modifiers: [.command])
                    .hidden()
            )
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
            .task(id: appLockEnabled) {
                // Launch lock: enabled + never unlocked this run.
                if appLockEnabled, lastUnlocked == nil {
                    locked = true
                }
            }
            .sheet(isPresented: $showingPalette) {
                CommandPalette(
                    notes: notesModel.notes.map {
                        ($0.id, URL(fileURLWithPath: $0.relativePath)
                            .deletingPathExtension().lastPathComponent)
                    },
                    onOpenNote: { id in
                        notesModel.openNote(id, jumpToLine: nil)
                        selectedTab = "notes"
                    },
                    onSwitchTab: { selectedTab = $0 },
                    onQuickAdd: { text in Task { await indexService.quickAdd(text) } },
                    onDailyNote: {
                        notesModel.openDailyNote()
                        selectedTab = "notes"
                    },
                    isPresented: $showingPalette
                )
            }
            .task {
                indexService.onNoteMutated = { [weak notesModel = notesModel] noteId in
                    notesModel?.reloadIfDisplayed(noteId: noteId)
                }
                indexService.beforeNoteMutation = { [weak notesModel = notesModel] noteId in
                    guard let notesModel, notesModel.selectedID == noteId else { return }
                    await notesModel.flushSave(allowRename: false)
                }
                await indexService.start()
            }
        #if os(macOS)
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
                Tab("Tags", systemImage: "number", value: "tags") {
                    tagsTab
                }
                #if DEBUG
                    Tab("Vault", systemImage: "icloud", value: "vault") {
                        vaultTab
                    }
                #endif
            }
            .tabViewStyle(.sidebarAdaptable)
        #endif
    }

    /// Plain switch: exactly ONE view in the hierarchy. Mounting all tabs
    /// at once kept every tab's TOOLBAR registered with the window, and
    /// the union of toolbar rows drove the window's minimum size past the
    /// screen (user-reported unresizable). Shared models carry the state
    /// that must survive switches; volatile view prefs live in AppStorage.
    @ViewBuilder private var mountedViews: some View {
        switch selectedTab {
        case "todo": todoTab
        case "projects": projectsTab
        case "tags": tagsTab
        #if DEBUG
            case "vault": vaultTab
        #endif
        default: notesTab
        }
    }

    private var tagsTab: some View {
        TagsView(service: indexService, model: notesModel) { id in
            notesModel.openNote(id, jumpToLine: nil)
            selectedTab = "notes"
        }
    }

    private var notesTab: some View {
        NotesView(indexService: indexService, model: notesModel)
    }

    private var todoTab: some View {
        TodoView(service: indexService, quickAddSignal: quickAddSignal) { noteId, line in
            notesModel.openNote(noteId, jumpToLine: line)
            selectedTab = "notes"
        }
    }

    private var projectsTab: some View {
        ProjectsView(service: indexService, newProjectSignal: newProjectSignal)
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
    AppShell()
}

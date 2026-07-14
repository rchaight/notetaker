import SecurityKit
import SwiftUI
#if os(macOS)
    import AppKit
#endif

/// Root shell: three sections as an adaptive TabView (sidebar on Mac/iPad,
/// tab bar on iPhone). Placeholder content until M1–M3 land.
struct AppShell: View {
    @State private var indexService = VaultIndexService()
    @State private var notesModel = NotesModel()
    @State private var selectedTab = "notes"
    @State private var showingPalette = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appLockGrace") private var appLockGrace = 60.0
    @State private var locked = false
    @State private var lastUnlocked: Date?
    @State private var backgroundedAt: Date?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Notes", systemImage: "note.text", value: "notes") {
                NotesView(indexService: indexService, model: notesModel)
            }
            Tab("To-Do", systemImage: "checklist", value: "todo") {
                TodoView(service: indexService) { noteId, line in
                    notesModel.openNote(noteId, jumpToLine: line)
                    selectedTab = "notes"
                }
            }
            Tab("Projects", systemImage: "calendar.day.timeline.left", value: "projects") {
                ProjectsView(service: indexService)
            }
            #if DEBUG
                // M1 sync-verification harness; visible on every platform in
                // debug builds only.
                Tab("Vault", systemImage: "icloud", value: "vault") {
                    NavigationStack {
                        VaultDebugView()
                            .navigationTitle("Vault")
                    }
                }
            #endif
        }
        #if os(macOS)
        // The beta's tab sidebar renders fixed-wide and non-resizable —
        // compact top tabs on macOS; iOS keeps the adaptive sidebar.
        .tabViewStyle(.automatic)
        #else
        .tabViewStyle(.sidebarAdaptable)
        #endif
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

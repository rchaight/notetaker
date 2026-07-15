import SwiftUI

@main
struct NotetakerApp: App {
    // Owned here so EVERY scene (main window, task-detail windows) shares
    // the same instances.
    @State private var indexService = VaultIndexService()
    @State private var notesModel = NotesModel()
    @State private var extrasStore = TaskExtrasStore()

    init() {
        // Dev builds change toolbars between installs; restoring a stale
        // saved toolbar plist crashes SwiftUI's NSToolbar bridge on the
        // macOS 27 beta (NSException in _insertNewItemWithItemIdentifier).
        // Purge saved window state before any window is created. Revisit
        // for proper state restoration at release (M10).
        Self.purgeSavedWindowState()
        VaultSmoke.runIfRequested()
        #if os(macOS)
            // System-wide quick capture (⌃⌥⌘N), registered once at launch.
            Task { @MainActor in GlobalHotkey.register() }
        #endif
    }

    private static func purgeSavedWindowState() {
        #if os(macOS)
            guard let library = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
            let savedState = library
                .appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent("com.rchaight.notetaker.savedState", isDirectory: true)
            try? FileManager.default.removeItem(at: savedState)
        #endif
    }

    @AppStorage(VaultRegistry.activeKey) private var activeVault = VaultRegistry.iCloudId

    var body: some Scene {
        WindowGroup {
            // .id: switching vaults rebuilds the shell (fresh model + index
            // service rooted in the new vault).
            AppShell(
                indexService: indexService,
                notesModel: notesModel,
                extrasStore: extrasStore
            )
            .id(activeVault)
        }
        .defaultSize(width: 1150, height: 720)

        WindowGroup("Task", id: "task-detail", for: String.self) { $taskId in
            if let taskId {
                TaskDetailView(
                    service: indexService,
                    extrasStore: extrasStore,
                    taskId: taskId
                ) { noteId, line in
                    notesModel.openNote(noteId, jumpToLine: line)
                }
            }
        }
        .defaultSize(width: 520, height: 480)
        .windowResizability(.contentSize)

        #if os(macOS)
            Settings {
                SettingsView()
            }
            MenuBarExtra("Notetaker Quick Add", systemImage: "square.and.pencil") {
                MenuBarQuickAddView()
            }
            .menuBarExtraStyle(.window)
        #endif
    }
}

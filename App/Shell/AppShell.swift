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

#Preview {
    AppShell()
}

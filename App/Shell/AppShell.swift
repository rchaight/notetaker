import SwiftUI

/// Root shell: three sections as an adaptive TabView (sidebar on Mac/iPad,
/// tab bar on iPhone). Placeholder content until M1–M3 land.
struct AppShell: View {
    var body: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesView()
            }
            Tab("To-Do", systemImage: "checklist") {
                NavigationStack {
                    ContentUnavailableView(
                        "No Tasks Yet",
                        systemImage: "checklist",
                        description: Text("Todos you write in notes will appear here.")
                    )
                    .navigationTitle("To-Do")
                }
            }
            Tab("Projects", systemImage: "folder") {
                NavigationStack {
                    ContentUnavailableView(
                        "No Projects Yet",
                        systemImage: "folder",
                        description: Text("Create a project to plan and track larger work.")
                    )
                    .navigationTitle("Projects")
                }
            }
            #if DEBUG
                // M1 sync-verification harness; visible on every platform in
                // debug builds only.
                Tab("Vault", systemImage: "icloud") {
                    NavigationStack {
                        VaultDebugView()
                            .navigationTitle("Vault")
                    }
                }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

#Preview {
    AppShell()
}

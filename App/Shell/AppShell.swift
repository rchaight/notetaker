import SwiftUI

/// Root shell: three sections as an adaptive TabView (sidebar on Mac/iPad,
/// tab bar on iPhone). Placeholder content until M1–M3 land.
struct AppShell: View {
    var body: some View {
        TabView {
            Tab("Notes", systemImage: "note.text") {
                NotesPlaceholder()
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
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// Notes gets the three-column skeleton the editor will live in.
private struct NotesPlaceholder: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("All Notes", systemImage: "tray.full")
            }
            .navigationTitle("Notes")
        } detail: {
            ContentUnavailableView(
                "No Note Selected",
                systemImage: "note.text",
                description: Text("Select or create a note.")
            )
        }
    }
}

#Preview {
    AppShell()
}

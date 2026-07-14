import IndexKit
import SwiftUI

/// Linear-style ⌘K palette: fuzzy note jump, tab switch, quick task add,
/// daily note — one keyboard-fast entry point over existing actions.
struct CommandPalette: View {
    let notes: [(id: String, title: String)]
    let onOpenNote: (String) -> Void
    let onSwitchTab: (String) -> Void
    let onQuickAdd: (String) -> Void
    let onDailyNote: () -> Void
    @Binding var isPresented: Bool

    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Command: Identifiable {
        let id: String
        let title: String
        let icon: String
        let action: () -> Void
    }

    private var commands: [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var results: [Command] = []
        if trimmed.lowercased().hasPrefix("add ") {
            let text = String(trimmed.dropFirst(4))
            results.append(Command(
                id: "add", title: "Add task: \(text)", icon: "plus.circle"
            ) { onQuickAdd(text) })
        }
        if trimmed.isEmpty || "today daily".contains(trimmed.lowercased()) {
            results.append(Command(id: "daily", title: "Open Today's Daily Note", icon: "calendar") {
                onDailyNote()
            })
        }
        for (name, key) in [("Notes", "notes"), ("To-Do", "todo"), ("Projects", "projects")]
            where trimmed.isEmpty || name.lowercased().contains(trimmed.lowercased()) {
            results.append(Command(id: "tab-\(key)", title: "Go to \(name)", icon: "arrow.right.square") {
                onSwitchTab(key)
            })
        }
        let lowered = trimmed.lowercased()
        for note in notes where lowered.isEmpty || note.title.lowercased().contains(lowered) {
            results.append(Command(id: "note-\(note.id)", title: note.title, icon: "note.text") {
                onOpenNote(note.id)
            })
            if results.count > 12 { break }
        }
        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search notes, \"add <task>\", or a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit {
                    if let first = commands.first {
                        run(first)
                    }
                }
            Divider()
            List(commands) { command in
                Button {
                    run(command)
                } label: {
                    Label(command.title, systemImage: command.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .frame(minHeight: 240, maxHeight: 320)
        }
        .frame(width: 560)
        .onAppear { focused = true }
    }

    private func run(_ command: Command) {
        isPresented = false
        query = ""
        command.action()
    }
}

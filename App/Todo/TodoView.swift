import IndexKit
import SwiftUI
import TaskEngine

/// The master To-Do tab: every inline `- [ ]` across the vault, live,
/// grouped into Overdue / Today / Upcoming / Inbox. Checking a row edits
/// the exact source line in the note.
struct TodoView: View {
    let service: VaultIndexService
    @State private var grouped: [SmartBucket: [TaskRecord]] = [:]
    @State private var showingQuickAdd = false
    @State private var quickAddText = ""

    private static let sections: [(SmartBucket, String, String)] = [
        (.overdue, "Overdue", "exclamationmark.circle"),
        (.today, "Today", "star"),
        (.upcoming, "Upcoming", "calendar"),
        (.inbox, "Inbox", "tray"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.sections, id: \.0) { bucket, title, icon in
                    if let tasks = grouped[bucket], !tasks.isEmpty {
                        Section {
                            ForEach(tasks) { task in
                                row(task)
                            }
                        } header: {
                            Label(title, systemImage: icon)
                                .foregroundStyle(bucket == .overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        }
                    }
                }
            }
            .overlay {
                if grouped.values.allSatisfy(\.isEmpty) || grouped.isEmpty {
                    ContentUnavailableView(
                        "No Open Tasks",
                        systemImage: "checklist",
                        description: Text("Write - [ ] anywhere in a note and it appears here.")
                    )
                }
            }
            .navigationTitle("To-Do")
            .toolbar {
                ToolbarItem {
                    Button("New Task", systemImage: "plus") {
                        showingQuickAdd = true
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Quick Add (⇧⌘N) — e.g. \"email dean tomorrow p1 #admin\"")
                }
            }
        }
        .sheet(isPresented: $showingQuickAdd) {
            quickAddSheet
        }
        .task {
            await service.start()
            refresh()
        }
        .onChange(of: service.tasksVersion) {
            refresh()
        }
    }

    private var quickAddSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Add")
                .font(.headline)
            TextField("email dean tomorrow p1 #admin", text: $quickAddText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitQuickAdd() }
            Text("Natural dates work (tomorrow, friday, jul 20) — or tokens: >date  !p1–p4  #label  &every 3 days")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingQuickAdd = false
                    quickAddText = ""
                }
                Button("Add Task") { submitQuickAdd() }
                    .buttonStyle(.borderedProminent)
                    .disabled(quickAddText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .presentationDetents([.height(200)])
    }

    private func submitQuickAdd() {
        let input = quickAddText
        showingQuickAdd = false
        quickAddText = ""
        Task { await service.quickAdd(input) }
    }

    private func refresh() {
        grouped = Dictionary(grouping: service.openTasks()) {
            SmartBuckets.bucket(dueDate: $0.dueDate)
        }
    }

    private func row(_ task: TaskRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                Task { await service.toggle(task) }
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(priorityColor(task.priority))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete task")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.text)
                HStack(spacing: 8) {
                    if let due = task.dueDate {
                        Label(due, systemImage: "calendar")
                    }
                    if let priority = task.priority {
                        Text("P\(priority)")
                            .fontWeight(.semibold)
                            .foregroundStyle(priorityColor(priority))
                    }
                    Text(noteName(task.noteId))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func noteName(_ noteId: String) -> String {
        URL(fileURLWithPath: noteId).deletingPathExtension().lastPathComponent
    }

    private func priorityColor(_ priority: Int?) -> Color {
        switch priority {
        case 1: .red
        case 2: .orange
        case 3: .blue
        default: .secondary
        }
    }
}

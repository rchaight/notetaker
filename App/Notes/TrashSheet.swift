import SwiftUI
import VaultKit

/// The vault's Trash (`<vault>/.trash/`): a live listing of the folder with Restore,
/// Delete Permanently and Empty Trash. Nothing here is stored anywhere but the folder itself
/// (spec ux-phase1/01) — the list is re-read from disk after every action.
struct TrashSheet: View {
    let model: NotesModel
    let indexService: VaultIndexService
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [VaultTrash.Entry] = []
    @State private var loaded = false
    @State private var working = false
    @State private var errorMessage: String?
    /// ONE confirmation dialog for both destructive actions, driven by this item.
    @State private var pending: PendingAction?

    private enum PendingAction {
        case purge(VaultTrash.Entry)
        case emptyAll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Trash", systemImage: "trash")
                    .font(.headline)
                Spacer()
                Button("Empty Trash", role: .destructive) { pending = .emptyAll }
                    .disabled(entries.isEmpty || working)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            content
            if let errorMessage {
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
        .sheetFrame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 440)
        .task { await reload() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pending != nil },
                set: {
                    if !$0 {
                        pending = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            switch action {
            case let .purge(entry):
                Button("Delete Permanently", role: .destructive) { purge(entry) }
            case .emptyAll:
                Button("Empty Trash", role: .destructive) { emptyAll() }
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "Trash is Empty",
                systemImage: "trash",
                description: Text("Notes you move to the Trash wait here until you restore or delete them.")
            )
        } else {
            List(entries) { entry in
                row(entry)
            }
        }
    }

    private func row(_ entry: VaultTrash.Entry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(of: entry))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(of: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                restore(entry)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .help("Restore to \(entry.originalPath)")
            Button(role: .destructive) {
                pending = .purge(entry)
            } label: {
                Label("Delete Permanently", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .help("Delete permanently")
        }
        .buttonStyle(.borderless)
        .disabled(working)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { restore(entry) }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) { pending = .purge(entry) }
        }
    }

    private var confirmationTitle: String {
        switch pending {
        case let .purge(entry):
            "Permanently delete “\(title(of: entry))”?"
        case .emptyAll:
            "Permanently delete \(entries.count) \(entries.count == 1 ? "note" : "notes")?"
        case nil:
            ""
        }
    }

    private func title(of entry: VaultTrash.Entry) -> String {
        NotesModel.noteTitle(ofPath: entry.originalPath)
    }

    private func subtitle(of entry: VaultTrash.Entry) -> String {
        let folder = entry.originalPath.split(separator: "/").dropLast().joined(separator: "/")
        var parts = [folder.isEmpty ? "Vault root" : folder]
        if let date = entry.modificationDate {
            parts.append("edited " + date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func reload() async {
        entries = await model.trashEntries()
        loaded = true
    }

    private func restore(_ entry: VaultTrash.Entry) {
        perform("Couldn't restore “\(title(of: entry))”") {
            try await model.restore(entry)
            // Put the note back in front of the index right away, not on the next watcher tick.
            await indexService.rescan()
        }
    }

    private func purge(_ entry: VaultTrash.Entry) {
        perform("Couldn't delete “\(title(of: entry))”") {
            try await model.purge(entry)
        }
    }

    private func emptyAll() {
        perform("Couldn't empty the Trash") {
            try await model.emptyTrash()
        }
    }

    private func perform(_ failure: String, _ action: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            do {
                try await action()
            } catch {
                errorMessage = "\(failure): \(error.localizedDescription)"
            }
            await reload()
            working = false
        }
    }
}

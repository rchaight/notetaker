import SwiftUI
import VaultKit

/// Rename Note (spec ux-phase2/05): the new name with live validation, and a dry-run preview of
/// the other notes whose `[[links]]` will be rewritten. The rename itself (file move, heading,
/// inbound links) runs in `perform`, while this sheet stays up showing progress, so nothing can
/// be typed into the note mid-rename.
struct RenameNoteSheet: View {
    let note: VaultItem
    let model: NotesModel
    let indexService: VaultIndexService
    /// Runs the whole rename; returns the message to show when it failed, nil on success.
    let perform: (String) async -> String?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selection: TextSelection?
    /// nil while scanning.
    @State private var rows: [LinkRewriteRow]?
    @State private var caughtUp = false
    @State private var working = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(
        note: VaultItem, model: NotesModel, indexService: VaultIndexService,
        perform: @escaping (String) async -> String?
    ) {
        self.note = note
        self.model = model
        self.indexService = indexService
        self.perform = perform
        _name = State(initialValue: NotesModel.noteTitle(ofPath: note.id))
    }

    private var oldTitle: String {
        NotesModel.noteTitle(ofPath: note.id)
    }

    private var cleaned: String {
        NotesModel.renameBaseName(name)
    }

    private var unchanged: Bool {
        cleaned == oldTitle
    }

    /// The reason Rename is disabled, as the line under the field shows it.
    private var problem: String? {
        // Once the rename is underway `note` is stale: its old path is gone and the name being
        // asked for belongs to this very file, so validating again would report "already exists".
        if working {
            return nil
        }
        if note.hasUnresolvedConflicts {
            return "This note has an unresolved sync conflict. Resolve it first."
        }
        if let error = model.renameProblem(note, to: name) {
            return NotesModel.message(for: error, base: cleaned)
        }
        return nil
    }

    private var canRename: Bool {
        !working && !unchanged && problem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rename Note", systemImage: "pencil")
                .font(.headline)
            TextField("Name", text: $name, selection: $selection)
                .focused($nameFocused)
                .onSubmit { submit() }
                .disabled(working)
            validationLine
            Divider()
            preview
            Text("Locked notes are never changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working {
                    ProgressView()
                        .controlSize(.small)
                    Text("Renaming…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRename)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .sheetFrame(width: 440)
        .interactiveDismissDisabled(working)
        .onAppear {
            selection = TextSelection(range: name.startIndex ..< name.endIndex)
            nameFocused = true
        }
        .task(id: cleaned) { await loadPreview() }
    }

    @ViewBuilder private var validationLine: some View {
        if let problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
        } else if !unchanged, cleaned != name.trimmingCharacters(in: .whitespaces) {
            Text("Will be saved as “\(cleaned)”")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var preview: some View {
        if let rows {
            let updating = rows.filter { $0.skipped == nil }
            let skipped = rows.filter { $0.skipped != nil }
            let links = updating.reduce(0) { $0 + $1.count }
            Text(updating.isEmpty ? "No other notes link here." : Self.summary(links: links, notes: updating.count))
                .font(.callout)
            if !rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(updating) { row in
                            rowView(row.title, icon: "link", detail: "\(row.count)", tint: .secondary)
                        }
                        ForEach(skipped) { row in
                            skippedRow(row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "3 links in 3 notes will be updated".
    private static func summary(links: Int, notes: Int) -> String {
        "\(links) link\(links == 1 ? "" : "s") in \(notes) note\(notes == 1 ? "" : "s") will be updated"
    }

    @ViewBuilder private func skippedRow(_ row: LinkRewriteRow) -> some View {
        switch row.skipped {
        case .locked:
            rowView(row.title, icon: "lock", detail: "Locked, not checked", tint: .secondary)
        case .conflicted:
            rowView(row.title, icon: "exclamationmark.icloud", detail: "Sync conflict, skipped", tint: .orange)
        case .noLinksFound, nil:
            rowView(row.title, icon: "checkmark", detail: "Nothing to change", tint: .secondary)
        }
    }

    private func rowView(_ title: String, icon: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    /// Dry run. The first pass flushes the editor so the file on disk is current. It does NOT
    /// rescan the vault: that walks every note on the main actor (many seconds on a phone, and
    /// it froze this sheet), and the rename's own rewrite step re-reads from disk before it
    /// writes anything, so a link typed a moment ago is still updated even if this preview
    /// hasn't counted it yet. While the name is unchanged or invalid the preview still counts
    /// the links that point here (a name no title can equal stands in for the new one).
    private func loadPreview() async {
        try? await Task.sleep(for: .milliseconds(caughtUp ? 250 : 0))
        guard !Task.isCancelled else { return }
        if !caughtUp {
            await model.flushSave(allowRename: false)
            caughtUp = true
        }
        // A rename is running: `note` is stale, and the sheet is about to close.
        guard !working else { return }
        let target = !unchanged && problem == nil ? cleaned : "\u{1}" + UUID().uuidString
        let result = await indexService.previewInboundLinks(
            toTitle: oldTitle, renamedTo: target, renamedId: note.id,
            among: model.notes.map { ($0.id, NotesModel.noteTitle(ofPath: $0.id)) },
            skipping: [note.id]
        )
        guard !Task.isCancelled else { return }
        rows = result
    }

    private func submit() {
        guard canRename else { return }
        working = true
        errorMessage = nil
        let requested = name
        Task {
            let failure = await perform(requested)
            working = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }
}

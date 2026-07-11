import EditorKit
import SwiftUI
import VaultKit

/// The Notes tab: vault note list on the left, live markdown editor on the
/// right. Every edit autosaves (debounced, coordinated) to the .md file.
struct NotesView: View {
    let indexService: VaultIndexService
    @State private var model = NotesModel()
    @State private var livePreview = true
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Notes")
                .toolbar {
                    ToolbarItem {
                        Button("New Note", systemImage: "square.and.pencil") {
                            model.createNote()
                        }
                        .keyboardShortcut("n", modifiers: [.command])
                    }
                }
        } detail: {
            detail
        }
        .searchable(text: $searchText, prompt: "Search all notes")
        .task { await model.start() }
        .onDisappear { Task { await model.flushSave() } }
    }

    @ViewBuilder private var sidebar: some View {
        switch model.state {
        case .loading:
            ProgressView("Opening vault…")
        case let .unavailable(message):
            ContentUnavailableView(
                "iCloud Unavailable",
                systemImage: "icloud.slash",
                description: Text(message)
            )
        case .ready, .readyLocalFallback:
            List(selection: Binding(
                get: { model.selectedID },
                set: { model.select($0) }
            )) {
                ForEach(visibleNotes) { note in
                    NavigationLink(value: note.id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(noteTitle(note))
                                if noteFolder(note) != nil {
                                    Text(noteFolder(note)!)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            syncBadge(note)
                        }
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.delete(note)
                        }
                    }
                }
            }
            .overlay {
                if visibleNotes.isEmpty {
                    ContentUnavailableView(
                        "No Notes Yet",
                        systemImage: "note.text",
                        description: Text("Press ⌘N or tap New Note to create your first markdown note.")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.state == .readyLocalFallback {
                    Label("Local vault — iCloud unavailable", systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.selectedID != nil {
            MarkdownEditor(
                text: Binding(
                    get: { model.noteText },
                    set: { model.noteText = $0; model.textChanged() }
                ),
                livePreview: livePreview
            )
            .overlay(alignment: .bottomTrailing) {
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
            }
            .toolbar {
                ToolbarItem {
                    Button(
                        livePreview ? "Source Mode" : "Live Preview",
                        systemImage: livePreview ? "chevron.left.forwardslash.chevron.right" : "eye"
                    ) {
                        livePreview.toggle()
                    }
                    .keyboardShortcut("/", modifiers: [.command])
                    .help(livePreview
                        ? "Show all markdown syntax (⌘/)"
                        : "Hide syntax except on the current line (⌘/)")
                }
            }
            .navigationTitle(selectedTitle)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "note.text",
                description: Text("Choose a note from the list, or create one.")
            )
        }
    }

    /// FTS-ranked results while searching; the full list otherwise.
    private var visibleNotes: [VaultItem] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return model.notes }
        let ranked = indexService.searchNoteIds(searchText)
        let byId = Dictionary(uniqueKeysWithValues: model.notes.map { ($0.id, $0) })
        return ranked.compactMap { byId[$0] }
    }

    private var selectedTitle: String {
        model.notes.first { $0.id == model.selectedID }.map(noteTitle) ?? "Note"
    }

    private var wordCount: Int {
        model.noteText.split(whereSeparator: \.isWhitespace).count
    }

    private func noteTitle(_ note: VaultItem) -> String {
        URL(fileURLWithPath: note.relativePath).deletingPathExtension().lastPathComponent
    }

    private func noteFolder(_ note: VaultItem) -> String? {
        let components = note.relativePath.split(separator: "/").dropLast()
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// Makes iCloud transit visible: slow sync should read as "in flight",
    /// never as "broken". No badge = fully synced.
    @ViewBuilder private func syncBadge(_ note: VaultItem) -> some View {
        if note.hasUnresolvedConflicts {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
                .help("Sync conflict — resolve in the Vault tab")
        } else if note.isUploading {
            Image(systemName: "icloud.and.arrow.up")
                .foregroundStyle(.secondary)
                .help("Uploading to iCloud…")
        } else if note.downloadState == .notDownloaded {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
                .help("Not downloaded yet")
        } else if note.downloadState == .downloaded {
            Image(systemName: "arrow.clockwise.icloud")
                .foregroundStyle(.secondary)
                .help("Newer version syncing down…")
        }
    }
}

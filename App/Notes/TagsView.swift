import AIKit
import IndexKit
import SwiftUI

/// Dedicated Tags tab: browse, filter, and curate every tag in the vault.
/// Left: searchable tag list + merge suggestions. Right: the notes carrying
/// the selected tag (open in the Notes tab with one click).
struct TagsView: View {
    let service: VaultIndexService
    let model: NotesModel
    /// Opens a note in the Notes tab (wired by AppShell).
    var openNote: (String) -> Void = { _ in }

    @State private var allTags: [(tag: String, count: Int)] = []
    @State private var selectedTag: String?
    @State private var search = ""
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var mergeSuggestions: [TagMerge] = []
    @State private var suggesting = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
                .navigationTitle("Tags")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            suggesting = true
                            Task {
                                mergeSuggestions = await service.suggestTagMerges()
                                suggesting = false
                            }
                        } label: {
                            Label("Suggest Merges", systemImage: "wand.and.stars")
                        }
                        .help("Find duplicate-ish tags to fold together (heuristics + local Ollama)")
                        .disabled(suggesting)
                    }
                }
        } detail: {
            detail
        }
        .task(id: service.tasksVersion) {
            allTags = service.noteTags()
        }
        .alert(
            "Rename Tag",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: {
                    if !$0 {
                        renameTarget = nil
                    }
                }
            )
        ) {
            TextField("New tag name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    let newName = renameText
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "#", with: "")
                    Task {
                        await service.renameTag(from: target, to: newName)
                        allTags = service.noteTags()
                        if selectedTag == target {
                            selectedTag = newName
                        }
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Rewrites #\(renameTarget ?? "") in every note that carries it.")
        }
    }

    private var filteredTags: [(tag: String, count: Int)] {
        allTags
            .filter { search.isEmpty || $0.tag.localizedCaseInsensitiveContains(search) }
            .sorted { $0.count > $1.count }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter tags…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    suggesting = true
                    Task {
                        mergeSuggestions = await service.suggestTagMerges()
                        suggesting = false
                    }
                } label: {
                    if suggesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                }
                .help("Suggest tag merges (heuristics + local Ollama when configured)")
                .disabled(suggesting)
            }
            .padding(10)
            if !mergeSuggestions.isEmpty {
                suggestionList
                Divider()
            }
            List(selection: $selectedTag) {
                ForEach(filteredTags, id: \.tag) { entry in
                    HStack {
                        Label(entry.tag, systemImage: "number")
                        Spacer()
                        Text("\(entry.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.tag)
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") {
                            renameText = entry.tag
                            renameTarget = entry.tag
                        }
                        Menu("Merge Into") {
                            ForEach(
                                allTags.filter { $0.tag != entry.tag }.map(\.tag).sorted(),
                                id: \.self
                            ) { other in
                                Button("#" + other) {
                                    Task {
                                        await service.renameTag(from: entry.tag, to: other)
                                        allTags = service.noteTags()
                                    }
                                }
                            }
                        }
                        Button(
                            "Remove Tag Everywhere", systemImage: "trash", role: .destructive
                        ) {
                            Task {
                                await service.deleteTag(entry.tag)
                                allTags = service.noteTags()
                                if selectedTag == entry.tag {
                                    selectedTag = nil
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if allTags.isEmpty {
                    ContentUnavailableView(
                        "No Tags Yet",
                        systemImage: "number",
                        description: Text("Write #topic in any note's text and it appears here.")
                    )
                }
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(mergeSuggestions) { merge in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(merge.from.joined(separator: ", #")) → #\(merge.into)")
                        .font(.callout)
                    HStack {
                        Text(merge.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") {
                            let suggestion = merge
                            mergeSuggestions.removeAll { $0.id == suggestion.id }
                            Task {
                                for source in suggestion.from {
                                    await service.renameTag(from: source, to: suggestion.into)
                                }
                                allTags = service.noteTags()
                            }
                        }
                        .controlSize(.small)
                        Button("Dismiss") {
                            mergeSuggestions.removeAll { $0.id == merge.id }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var detail: some View {
        if let selectedTag {
            let ids = Set(service.tagNoteIds(selectedTag))
            let notes = model.notes.filter { ids.contains($0.id) }
            List(notes) { note in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            URL(fileURLWithPath: note.relativePath)
                                .deletingPathExtension().lastPathComponent
                        )
                        let folder = note.relativePath.split(separator: "/").dropLast()
                            .joined(separator: "/")
                        if !folder.isEmpty {
                            Text(folder)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { openNote(note.id) }
                .help("Open in Notes")
            }
            .navigationTitle("#" + selectedTag)
        } else {
            ContentUnavailableView(
                "Select a Tag",
                systemImage: "number",
                description: Text("Pick a tag to see every note that carries it.")
            )
        }
    }
}

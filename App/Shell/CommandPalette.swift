import IndexKit
import SwiftUI

/// Linear-style ⌘K launcher: ranked note jump, every available menu command
/// (the same `ShellCommand` table the menu bar builds from), recent notes when
/// the field is empty, note-body hits from the FTS index, and `add <task>`.
/// Ranking is `PaletteRanking` (IndexKit, unit-tested); this view only renders
/// it and routes the keyboard.
struct CommandPalette: View {
    let notes: [PaletteRanking.Note]
    /// Note ids, newest first (`NotesModel.recents`).
    let recents: [String]
    /// The commands available right now, with the title to show (a few flip
    /// with state, like Lock Note / Remove Lock).
    let commands: [(command: ShellCommand, title: String)]
    /// FTS note ids for body text; called off the keystroke path (debounced).
    let searchBodies: (String) -> [String]
    let onOpenNote: (String) -> Void
    let onCommand: (ShellCommand) -> Void
    let onQuickAdd: (String) -> Void
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var highlighted = 0
    /// Raw FTS ids for the current query; turned into rows (minus anything
    /// already listed as a title hit) at render time.
    @State private var bodyIDs: [String] = []
    @State private var cache = RankCache()
    @FocusState private var focused: Bool

    private enum Row: Identifiable {
        case quickAdd(String)
        case candidate(PaletteRanking.Candidate)

        var id: String {
            switch self {
            case .quickAdd: "add"
            case let .candidate(candidate): candidate.id
            }
        }
    }

    /// Ranking runs over every note title, so it is computed once per query,
    /// not once per body pass or key press. Reference type on purpose: it is
    /// written while rendering (same pattern as `ReadingPositionBox`).
    private final class RankCache {
        var query: String?
        var rows: [PaletteRanking.Candidate] = []
    }

    private static let bodySearchMinimum = 3
    private static let bodySearchDelay = Duration.milliseconds(150)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// "add call Amber >friday" → "call Amber >friday"; nil otherwise.
    private var quickAddText: String? {
        trimmedQuery.lowercased().hasPrefix("add ") ? String(trimmedQuery.dropFirst(4)) : nil
    }

    private var ranked: [PaletteRanking.Candidate] {
        if cache.query == query {
            return cache.rows
        }
        let rows = PaletteRanking.rank(
            query: query,
            commands: commands.map { (id: $0.command.rawValue, title: $0.title, shortcut: $0.command.shortcutLabel) },
            notes: notes,
            recents: recents
        )
        cache.query = query
        cache.rows = rows
        return rows
    }

    /// The quick-add row (pinned first) and the ranked commands / notes.
    private var resultRows: [Row] {
        (quickAddText.map { [Row.quickAdd($0)] } ?? []) + ranked.map(Row.candidate)
    }

    /// Notes found by their text rather than their title.
    private var bodyRows: [Row] {
        PaletteRanking.bodyHits(bodyIDs, notes: notes, excluding: ranked).map(Row.candidate)
    }

    private var currentRows: [Row] {
        resultRows + bodyRows
    }

    private func moveHighlight(by step: Int) {
        let count = currentRows.count
        guard count > 0 else { return }
        // From where the highlight is drawn: the list may have shrunk under a stale index.
        highlighted = max(0, min(min(highlighted, count - 1) + step, count - 1))
    }

    private func runHighlighted() {
        let rows = currentRows
        guard !rows.isEmpty else { return }
        run(rows[min(highlighted, rows.count - 1)])
    }

    var body: some View {
        let results = resultRows
        let textHits = bodyRows
        let rows = results + textHits
        let active = rows.isEmpty ? 0 : min(highlighted, rows.count - 1)
        VStack(spacing: 0) {
            TextField("Search notes, commands, or \"add <task>\"…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                // These read the rows when they fire, not from this pass: SwiftUI does not re-run a
                // text field's modifiers when only the async body hits change, so a row list captured
                // here is stale (Return then found nothing to run).
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    isPresented = false
                    return .handled
                }
                .onSubmit { runHighlighted() }
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(results) { row in
                        rowView(row, highlighted: row.id == rows[safe: active]?.id)
                    }
                    if !textHits.isEmpty {
                        Section("In note text") {
                            ForEach(textHits) { row in
                                rowView(row, highlighted: row.id == rows[safe: active]?.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) {
                    let rows = currentRows
                    if let row = rows[safe: min(highlighted, rows.count - 1)] {
                        proxy.scrollTo(row.id, anchor: .center)
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: 400)
        }
        .sheetFrame(width: 560)
        .onAppear { focused = true }
        // A new query means a new list: start at the top.
        .onChange(of: results.map(\.id)) { highlighted = 0 }
        .task(id: query) { await searchBodyText() }
    }

    /// Debounced FTS lookup, so typing never waits on the database. Short
    /// queries and `add …` clear the section; a longer query keeps the last
    /// hits on screen (already de-duplicated against the current title rows)
    /// until the new ones land, which avoids a flicker per keystroke.
    private func searchBodyText() async {
        let text = trimmedQuery
        guard text.count >= Self.bodySearchMinimum, quickAddText == nil else {
            bodyIDs = []
            return
        }
        try? await Task.sleep(for: Self.bodySearchDelay)
        guard !Task.isCancelled else { return }
        bodyIDs = searchBodies(text)
    }

    private func rowView(_ row: Row, highlighted: Bool) -> some View {
        Button {
            run(row)
        } label: {
            HStack(spacing: 8) {
                switch row {
                case let .quickAdd(text):
                    Label("Add task: \(text)", systemImage: "plus.circle")
                case let .candidate(candidate):
                    candidateLabel(candidate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(highlighted))
    }

    @ViewBuilder private func rowBackground(_ highlighted: Bool) -> some View {
        if highlighted {
            Rectangle().fill(.selection)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func candidateLabel(_ candidate: PaletteRanking.Candidate) -> some View {
        switch candidate.kind {
        case let .command(id):
            Label(candidate.title, systemImage: ShellCommand(rawValue: id)?.systemImage ?? "command")
            Spacer(minLength: 8)
            if let shortcut = candidate.subtitle {
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
        case .note:
            Label(candidate.title, systemImage: "note.text")
            Spacer(minLength: 8)
            if let folder = candidate.subtitle {
                subtitle(folder)
            }
        case .bodyHit:
            Label(candidate.title, systemImage: "text.alignleft")
            Spacer(minLength: 8)
            subtitle(candidate.subtitle.map { "\($0) · in note text" } ?? "in note text")
        }
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
    }

    /// Close first, so the action runs against the window the palette was
    /// covering (sheets and dialogs it raises have nothing to collide with).
    private func run(_ row: Row) {
        isPresented = false
        query = ""
        switch row {
        case let .quickAdd(text):
            onQuickAdd(text)
        case let .candidate(candidate):
            switch candidate.kind {
            case let .command(id):
                if let command = ShellCommand(rawValue: id) {
                    onCommand(command)
                }
            case let .note(id), let .bodyHit(id):
                onOpenNote(id)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

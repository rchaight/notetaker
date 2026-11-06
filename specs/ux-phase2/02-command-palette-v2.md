# 02 — Command palette v2

## Goal

⌘K becomes a real launcher: ranked note matches, keyboard navigation, the full command list from spec 01, recents when empty, and body-text hits from the existing FTS5 index. Ranking is a pure function in IndexKit with tests.

## Verified findings

- `App/Shell/CommandPalette.swift` (91 lines): titles only, `contains` substring (`:45`), stops at 12 results, four hard-coded "Go to" commands (`:38-43`), `add ` prefix (`:27-32`), daily note (`:33-37`), `onSubmit` runs the first row (`:63-67`), no arrow keys, no highlight, no escape handling. Presented as a `.sheet` from `AppShell.swift:90-108` on both platforms, with `sheetFrame(width: 560)`.
- FTS5 exists: `IndexDatabase.searchNoteIds(matching:limit:)` (`IndexKit/IndexDatabase.swift:166-178`, BM25) wrapped by `VaultIndexService.searchNoteIds(_:)` (`VaultIndexService.swift:1224-1231`, quotes and prefix-matches each term). Headings are not indexed separately (body text only) — heading-level targets are a non-goal.
- Recents: `NotesModel.recents` (`NotesModel.swift:59-60`, UserDefaults `recentNotes`, newest first, max 8) — the palette uses this, not the sidebar's by-modified "Recents" section.
- `onKeyPress` is available at the 26.0 floor.

## Design

### IndexKit: `Sources/IndexKit/PaletteRanking.swift` (new, Foundation only)

```swift
public enum PaletteRanking {
    public struct Note: Sendable, Equatable { public let id: String; public let title: String; public let folder: String? }
    public struct Candidate: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case command(String), note(String), bodyHit(String) }
        public let id: String        // "cmd:newNote" / "note:<id>" / "body:<id>"
        public let kind: Kind
        public let title: String
        public let subtitle: String? // folder for notes, shortcut label for commands
        public let score: Int
    }
    /// nil = no match. Multi-token queries: every token must match; scores add.
    public static func score(query: String, title: String) -> Int?
    /// Empty query → recents (max 5, in order, score 0) then the first 8 commands in table order.
    /// Otherwise commands (≤ 6) then notes (≤ 10), each sorted by score desc, then title.
    public static func rank(
        query: String,
        commands: [(id: String, title: String, shortcut: String?)],
        notes: [Note],
        recents: [String]
    ) -> [Candidate]
    /// Body hits from FTS, minus ids already listed, max 5.
    public static func bodyHits(_ ids: [String], notes: [Note], excluding: [Candidate]) -> [Candidate]
}
```

`score` (case- and diacritic-insensitive via `folding(options: [.caseInsensitive, .diacriticInsensitive])`): exact 1000; prefix 800; any word prefix 600; substring 400; in-order subsequence 200 (chars of the token appear in order); otherwise nil. Subtract `title.count / 10` so shorter titles win ties. Recents bonus in `rank`: `+ (100 - 10 × index)` for ids in `recents`. Notes whose folder matches a token (`folder` contains token) get substring credit for that token.

### App: `CommandPalette.swift` rewrite (same file, same presentation)

Inputs: `notes: [PaletteRanking.Note]` (from `notesModel.notes`: id, title = file name sans `.md`, folder), `recents: notesModel.recents`, `commands: ShellCommand.allCases.filter { $0.isAvailable(bus) }` mapped to `(id, title, shortcutLabel)`, `searchBodies: (String) -> [String]` (= `indexService.searchNoteIds`), `onOpenNote`, `onCommand: (ShellCommand) -> Void` (= `bus.perform`), `onQuickAdd`, `isPresented`. Remove `onSwitchTab`/`onDailyNote` (now commands).

Rows: the `add ` prefix row stays pinned first when present. Then `PaletteRanking.rank(...)`, then a "In note text" section from `bodyHits` filled by `.task(id: query)` after a 150 ms sleep when `query.count >= 3` (so typing never blocks on FTS). Command rows: `Label(title, systemImage)` + trailing `shortcutLabel` in `.secondary`; note rows: title + folder subtitle; body rows: title + "in note text".

Keyboard: `@State highlighted = 0`, reset to 0 whenever the row list changes. On the TextField: `.onKeyPress(.downArrow) { highlighted = min(highlighted + 1, rows.count - 1); return .handled }`, `.upArrow` symmetric, `.escape` → `isPresented = false`, `onSubmit` runs `rows[highlighted]`. `ScrollViewReader` + `proxy.scrollTo(rows[highlighted].id, anchor: .center)` on change. Highlighted row background `.selection`; hover does not move the highlight; click runs the row. Keep `focused = true` on appear, the 560 pt frame, `minHeight 240 / maxHeight 320` (raise max to 400).

`run`: close, clear query, then the action. Command rows call `onCommand`, so the palette and the menu execute the same handler (spec 01's bus).

## Acceptance criteria

1. "pl" lists "Plan" above "Deployment Plan" above "Sample" (prefix > word-prefix > subsequence) — covered by a test with those strings.
2. ↓ ↓ ↩ opens the third row; ⎋ closes; ↑ at the top stays; the highlighted row is always visible.
3. Empty query: up to 5 recents then 8 commands; `add x` still quick-adds.
4. A query that matches only a body shows the note under "In note text" within ~200 ms and never duplicates a title hit.
5. Every available `ShellCommand` is reachable by name; unavailable ones (e.g. Bold while in Reading mode) are absent.

## Files expected to change

`Packages/IndexKit/Sources/IndexKit/PaletteRanking.swift` (new), `Packages/IndexKit/Tests/IndexKitTests/PaletteRankingTests.swift` (new), `App/Shell/CommandPalette.swift`, `App/Shell/AppShell.swift` (call site `:90-108`).
Must NOT touch: `IndexDatabase.swift` (FTS stays as is), `NotesModel.swift` (recents already public).

## Tests (IndexKit, Swift Testing)

`PaletteRankingTests`: `exactBeatsPrefixBeatsWordPrefixBeatsSubstringBeatsSubsequence`, `noMatchIsNil`, `multiTokenRequiresEveryToken`, `shorterTitleWinsTies`, `recentsBonusReordersEqualScores`, `emptyQueryListsRecentsThenCommands`, `commandAndNoteLimits`, `bodyHitsExcludeListedIds`, `foldsCaseAndDiacritics` ("resume" matches "Résumé"). Run: `cd Packages/IndexKit && DEVELOPER_DIR=/Applications/Xcode.app swift test --scratch-path ~/.cache/notetaker-build/IndexKit`.

## Regression guard

- ⌘K and the ribbon's command button still open it (`AppShell.swift:339-341`); the sheet still fits the iPhone (`sheetFrame`).
- Opening a note from the palette still switches to the Notes tab and opens the note (`AppShell.swift:96-99`).
- Quick Add via `add …` still goes through `indexService.quickAdd` (token-preserving path from Phase 1).

## Non-goals

Typo tolerance / true fuzzy matching; match highlighting in rows; searching tasks, tags or people; heading targets; frecency beyond the existing recents; an iOS entry point (the sheet keeps working with a hardware ⌘K); theming.

## Builder model

sonnet.

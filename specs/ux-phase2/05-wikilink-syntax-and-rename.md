# 05 — One wikilink grammar; Rename note with inbound link rewrite

## Goal

One parser/rewriter/resolver for `[[…]]` in MarkdownKit (pure), used by the indexer, the editor styling, Reading mode, the graph and the new Rename. Renaming a note moves the file (coordinated), keeps its heading in sync, rewrites every inbound link in other notes (coordinated, one file at a time), previews the blast radius first, and offers Undo. The index stays derived: it only nominates candidates; the files decide.

## Invariant

Every write here is a coordinated write of plain `.md` text through `VaultFileStore` (`move`, `writeString`), followed by `indexer.index`. No rename state lives outside the files; a crash at any point leaves every file valid markdown and the index rebuildable by `rescan()`.

## Verified findings

- Three regexes disagree:
  - `NoteScanner.wikilinkRegex` (`MarkdownKit/NoteScanner.swift:30-32`): target excludes `#` and `|` → `[[Plan|x]]`, `[[Plan#H]]` → "Plan" (correct for backlinks).
  - `MarkdownStyler.wikilinkRegex` (`StyleRanges.swift:73-75`): captures everything between the brackets → `.wikilink(target: "Plan|x")`. ReadingKit copies this (`ReadingDocument.swift:115-123, 376-377`), displays it as the link text (`ReadingInlineText.swift:92-95, 166`) and the tap sends "Plan|x" to `NotesView.openWikilink` (`NotesView.swift:1518-1525`), which compares whole titles → **aliased and heading links are unclickable in Reading mode and render wrong**.
  - `Autocomplete` (`EditorKit/Autocomplete.swift:35-39`) only detects an open `[[`; fine.
- Resolution is title-based, case-insensitive, first-wins in three places: `openWikilink` (`:1520-1525`), `GraphView` (`:25-27, 61-63`), `IndexDatabase.backlinks(toTitle:)` (`COLLATE NOCASE`, `IndexDatabase.swift:215-223`). `OutLinkRecord.targetTitle` stores the title string (`NoteIndexer.swift:105-107`).
- Rename today = title-sync only: `renameToMatchTitle` (`NotesModel.swift:470-495`) renames the file to its first heading after each save (`commit`, `:450-452`, unless `allowRename: false`). **Any rename must therefore set the heading too**, or the next autosave renames the file back.
- **Already fixed before Phase 2 (2026-11-06, own commit):** `move(toFolder:)` used to retarget only `openTabs`/`selectedID` — not `loadedURL`, `recents` or the unlock key — so typing after Move To recreated the note at its OLD path, and for an unlocked locked note that file was **plaintext**. `unlockedKeys` is now an `UnlockedKeyring` (SecurityKit) with `rekey(from:to:)`, and `move(toFolder:)` calls it and retargets `loadedURL` and `recents`. Rename must reuse the same calls (see §Algorithm step 5). `renameToMatchTitle` is unreachable for locked notes because `commit` returns early.
- `VaultFileStore.move` is dual-URL coordinated and refuses to overwrite (`VaultFileStore.swift:49-77`); `writeString` is atomic (`:33-41`). `VaultNaming.isTaken`/`uniqueFileName` exist (`VaultNaming.swift:8,20`).
- Locked notes: `NoteIndexer` indexes no links/tasks/body for `locked: true` (`NoteIndexer.swift:59-66`), so they never appear as backlink candidates; their body is ciphertext (`LockedNoteFile`, SecurityKit).
- Conflicts: `VaultItem.hasUnresolvedConflicts` (`VaultItem.swift:21`); `VaultConflictCenter.unresolvedVersions(for:)` (`Conflicts.swift:148`).
- Precedent for "rewrite N notes under coordination": `VaultIndexService.renameTag` (`VaultIndexService.swift:955-977`): `beforeNoteMutation` → read → regex → `writeString` → `indexer.index` → `knownMTimes[id] = nil` → `onNoteMutated`.
- `MarkdownDocument` splits frontmatter and exposes `body`, `bodyUTF16Offset`, `render()` (`MarkdownDocument.swift:6-34`). `MarkdownStyler.styleRanges(in:)` returns code ranges usable as exclusions (`StyleRanges.swift:93-104`).

## Design

### MarkdownKit: `Sources/MarkdownKit/Wikilinks.swift` (new; Foundation only)

```swift
public struct Wikilink: Equatable, Sendable, Hashable {
    public let raw: String        // text between the brackets, untrimmed
    public let target: String     // path-or-title part, trimmed ("" for [[#Heading]])
    public let heading: String?   // after "#", before "|", unless it starts with "^"
    public let blockId: String?   // after "#^"
    public let alias: String?     // after "|"
    public let isEmbed: Bool      // preceded by "!"
    public let range: NSRange     // whole [[…]] (or ![[…]]), in the scanned string's UTF-16 coordinates
    public let targetRange: NSRange // the trimmed target characters inside `range`
    public var title: String      // last "/" component of target
    public var label: String      // alias ?? (heading.map { "\(title) › \($0)" } ?? title) — Reading display
}
public enum WikilinkSyntax {
    static let regex = try? NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]+?)\]\]"#)
    public static func links(in text: String, excluding: [NSRange] = []) -> [Wikilink]
    public static func parse(inner raw: String) -> (target: String, heading: String?, blockId: String?, alias: String?)
    /// Replaces the target of every link whose `title` equals `old` (case-insensitive) with `new`,
    /// keeping any path prefix, heading, block id, alias and surrounding whitespace. Returns the
    /// new text and the number of links changed. Pure; idempotent.
    public static func rewrite(_ text: String, renamingTitle old: String, to new: String, excluding: [NSRange] = []) -> (text: String, count: Int)
    /// Title resolution shared by every click/graph site.
    public static func resolve(_ link: Wikilink, among notes: [(id: String, title: String)], from sourceId: String?) -> String?
    /// 0-based line of a heading (text after #s, trimmed, case-insensitive) or a block id (line ends with "^id").
    public static func anchorLine(heading: String?, blockId: String?, in text: String) -> Int?
}
```

Grammar table (tests mirror it):

| source | target | heading | blockId | alias | note |
|---|---|---|---|---|---|
| `[[Plan]]` | Plan | – | – | – | |
| `[[Plan\|the plan]]` | Plan | – | – | the plan | |
| `[[Plan#Budget]]` | Plan | Budget | – | – | |
| `[[Plan#Budget\|see]]` | Plan | Budget | – | see | |
| `[[Plan#^abc12]]` | Plan | – | abc12 | – | |
| `[[Projects/Plan]]` | Projects/Plan | – | – | – | `title` = Plan |
| `[[ Plan ]]` | Plan | – | – | – | `targetRange` covers "Plan" only |
| `[[#Budget]]` | "" | Budget | – | – | self link; never rewritten |
| `[[a\|b\|c]]` | a | – | – | b\|c | first `\|` splits |
| `![[Plan]]` | Plan | – | – | – | `isEmbed`; rewritten like a link |
| `[[]]`, `[[a` , `[[a\nb]]` | — | | | | not links |
| `` `[[x]]` `` / fenced | — | | | | only when the caller passes code ranges in `excluding` |

`resolve`: if `target` contains "/" and `notes` has id == `target + ".md"` (case-insensitive) → that id; else candidates = notes whose title == `link.title` (case-insensitive); none → nil; one → it; several → the one in `sourceId`'s folder, else the shortest id, else lexicographic. `rewrite` iterates matches last-to-first and replaces `targetRange` only (so `[[ Old ]]` → `[[ New ]]`; `[[Projects/Old#H|x]]` → `[[Projects/New#H|x]]`).

Adopt it:
- `NoteScanner.wikilinkTargets` → `WikilinkSyntax.links(in:).map(\.title)` deduped (behaviour unchanged for the existing test; `[[Projects/Plan]]` now yields "Plan" — new test).
- `StyleRanges`: `MarkdownElementKind.wikilink(target: String)` becomes `.wikilink(Wikilink)`; `appendExtendedSyntax` uses `WikilinkSyntax.links(in: body, excluding: codeRanges)`. Update every `case .wikilink` site: `SyntaxMarkers.swift:125` (pattern only), `ProofingExclusions.swift:48` (pattern only), `MarkdownTheme.swift:269` (pattern only), `ReadingDocument.swift:121, 376-377`, `ReadingBlock.swift:17` → `case wikilink(Wikilink)`, `ReadingInlineText.swift:92-95` (run text = `link.label`, URL carries `link.raw`), `:166` (plain text = `link.label`), `ReadingView.swift:122-129` (`onOpenNote` passes the raw inner text), tests `SyntaxMarkerTests.swift:86`, `ReadingDocumentTests.swift:90,100,115`, `EditorKit RevealScopeTests.swift:136`, `ProofingTests.swift:90` (grep `.wikilink(` in all four packages).
- `GraphView` and `NotesView.openWikilink` resolve via `WikilinkSyntax.resolve` (NotesView part in group C3; GraphView keeps its own dictionary — it draws edges by title and is not a navigation site; non-goal).

### App: rename

**`NotesModel`** (group C3):

```swift
struct RenameReceipt: Equatable { let oldId: String; let newId: String; let oldTitle: String; let newTitle: String }
enum RenameError: Error { case invalidName, nameTaken, hasConflicts, saveFailed, moveFailed(String) }
private(set) var lastRenamed: RenameReceipt?      // Undo toast, 6 s, same pattern as lastTrashed
private(set) var renameFailure: String?
func rename(_ item: VaultItem, to requestedTitle: String) async -> Result<RenameReceipt, RenameError>
func undoLastRename() async                        // rename(newId → oldTitle) through the same path
func dismissRenameNotice()
```

Order of operations in `rename` (each step's failure stops the sequence and is reported; earlier steps are not rolled back — see "Failure story"):

1. `newBase = Self.sanitizeFileName(requestedTitle)`; empty → `.invalidName`. `oldBase = item title`. Same string → return success without doing anything. `caseOnly = newBase.lowercased() == oldBase.lowercased()`. `destination = item.url.deletingLastPathComponent()/"\(newBase).md"`. `!caseOnly && VaultNaming.isTaken(destination)` → `.nameTaken`. `item.hasUnresolvedConflicts` → `.hasConflicts`.
2. If the note is open (`selectedID == item.id`): `await flushSave(allowRename: false)`; if still `dirty` after that → `.saveFailed`.
3. **Heading sync, under the old path.** Read the current text (open: `noteText`; else `store.readString`). If `Self.headingTitle(of:)` is non-nil, replace the text of that first heading line with `newBase` (keep the `#` level and trailing `\r` if any). Open note: assign `noteText`, mark `dirty`, `await flushSave(allowRename: false)`; closed note: `store.writeString`. Failure → `.saveFailed`. (Rationale: with the heading already saying New, a crash before step 4 is healed forward by title-sync on the note's next save; a failed move leaves a note whose next save completes the rename.)
4. **Move.** `try await store.move(from: item.url, to: destination)`. For `caseOnly`, on a thrown error retry through a temp name in the same folder (`<old>.md.renaming-<uuid>` → `<new>.md`, both coordinated moves). Failure → `.moveFailed`.
5. **Retarget in-memory state**: `selectedID`, `loadedURL`, `openTabs`, `recents` (+ UserDefaults), `ui.notes.lastSelectedNote` (spec 03), and **`unlockedKeys.rekey(from: oldId, to: newId)`** (`UnlockedKeyring`, SecurityKit; already used by `move(toFolder:)` — copy the retarget block from there rather than re-deriving it).
6. **Self links**: if the note's own body contains links to `oldBase`, rewrite them with `WikilinkSyntax.rewrite(excluding: code ranges)` the same way as step 3 (open → `noteText` + flush; closed → write). Skip for locked notes (body is ciphertext — the open-note path works on the decrypted `noteText`, which is fine, it re-encrypts on save).
7. `apply(VaultEnumerator.snapshot(of: root))`; `lastRenamed = receipt`.
8. Caller (`NotesView`) then runs `await indexService.rewriteInboundLinks(oldTitle:newTitle:skipping: [oldId, newId])` and `await indexService.rescan()` (so the renamed note is indexed under its new id and the old row is pruned).

**`VaultIndexService`** (group C3), next to `renameTag`:

```swift
struct LinkRewriteRow: Identifiable, Equatable { let id: String /* note id */; let title: String; let count: Int; let skipped: SkipReason? }
enum SkipReason: Equatable { case locked, conflicted, noLinksFound }
struct LinkRewriteReport: Equatable { var updated: [LinkRewriteRow]; var skipped: [LinkRewriteRow]; var failed: [(id: String, reason: String)] }
/// Dry run: reads each candidate, never writes.
func previewInboundLinks(toTitle old: String, renamedTo new: String, skipping: Set<String>) async -> [LinkRewriteRow]
/// Writes. `only` restricts to the given ids (Try Again).
func rewriteInboundLinks(oldTitle old: String, newTitle new: String, skipping: Set<String>, only: Set<String>? = nil) async -> LinkRewriteReport
```

Per candidate (`database.backlinks(toTitle: old)` minus `skipping`, sorted): `await beforeNoteMutation?(id)`; `store.readString`; `MarkdownDocument`; `frontmatter.values["locked"] == "true"` → `.locked` (never read the body as prose, never write); `!VaultConflictCenter().unresolvedVersions(for: url).isEmpty` → `.conflicted`; `codeRanges` from `MarkdownStyler.styleRanges(in: document.body)` shifted by `bodyUTF16Offset`… simpler: run `rewrite` on `document.body` with body-relative code ranges, then `MarkdownDocument(frontmatter:body:).render()`; `count == 0` → `.noLinksFound` (stale index, no write); else `writeString`, `indexer.index`, `knownMTimes[id] = nil`, `onNoteMutated?(id)`. Any thrown error → `failed`. Continue with the next candidate regardless. `tasksVersion += 1` at the end. `.trash/` notes are never candidates (never indexed) and the service never enumerates them.

**`App/Notes/RenameNoteSheet.swift`** (new): `TextField` prefilled with the title and fully selected; a live validation line ("Name can't be empty", "“X” already exists in this folder", "Will be saved as “Y”" when sanitising changed it); a preview list loaded in `.task(id: trimmedName)` via `previewInboundLinks` ("Scanning…", then "N links in M notes will be updated" + rows; skipped rows with a lock/⚠︎ icon and reason; "Locked notes are never changed." footer always); Cancel (⎋) / Rename (↩, `.borderedProminent`, disabled while invalid). `sheetFrame(width: 440)` so it fits the phone. On Rename: run steps above; on success close and show the toast "Renamed “Old” to “New” — Undo" in the sidebar bottom inset next to `trashNotice` (`NotesView.swift:743-774`; add `renameNotice` with the same 6 s `.task(id:)` pattern). If `report.failed` is non-empty: an alert listing the notes with "Try Again" (calls `rewriteInboundLinks(only:)`) and "OK".

Entry points: context menu "Rename…" after Duplicate (`NotesView.swift:2184`; both platforms), ⋯ overflow "Rename…" first item (spec 04, macOS), title-row double-click (spec 04), File ▸ Rename Note… ⌥⌘R and palette (spec 01's `renameNote`, now enabled when `hasOpenNote`). All set `renameCandidate: VaultItem?` which drives `.sheet(item:)`.

### Failure story

- Step 1-2 failures: nothing changed. Step 3 failure: nothing changed on disk (write failed). Step 4 failure after step 3: heading says New, file still Old; the next save of that note (title-sync) completes the rename; the UI reports "Couldn't rename: <error>". Step 6/8 failure: file is renamed, some links dangle, each failure listed with Try Again; Undo is still offered and reverses what did happen. 5th of 12 inbound fails: 11 are rewritten, one is listed; nothing stops. Crash anywhere: every file is intact (atomic writes, coordinated move); `rescan()` at next launch rebuilds the index; dangling links show in the graph/backlinks as unresolved — no silent corruption, no half-written file.
- Undo = `rename(newId → oldTitle)` (same checks: refuses if Old is now taken; reports). Candidates for the reverse are `backlinks(toTitle: new)`, i.e. exactly the notes just rewritten plus any that already linked to New (also correct to rewrite, since the note New no longer exists afterwards).

### Why opus

The sequence interleaves with the debounced autosave (`saveTask`, 800 ms), `renameToMatchTitle`, `beforeNoteMutation`/`onNoteMutated` reload hooks, `unlockedKeys` (plaintext-on-disk if wrong), coordinated moves on iCloud, and the index's `knownMTimes` cache. Getting any ordering wrong corrupts user data or silently reverts the rename. Package halves (MarkdownKit/ReadingKit) are mechanical: sonnet.

## Acceptance criteria

1. Grammar table passes as tests; `NoteScannerTests.extractsWikilinkTargets` unchanged; Reading mode shows "the plan" for `[[Plan|the plan]]` and opens Plan.
2. Rename "Plan" → "Plan 2026" with `[[Plan]]`, `[[Plan|the plan]]`, `[[Plan#Budget]]`, `[[Projects/Plan]]` in four notes and `` `[[Plan]]` `` in a fifth: preview says 4 links in 4 notes; after Rename: file `Plan 2026.md`, H1 `# Plan 2026`, four links rewritten with alias/heading/path kept, the code span untouched, Backlinks inspector lists four, index `backlinks(toTitle: "Plan")` empty after rescan.
3. Undo within 6 s restores the name, H1 and all four links.
4. Existing name → refused with the message, nothing written. Conflicted note → refused. Case-only rename succeeds.
5. A locked note linking to Plan: listed as skipped; its bytes identical before/after (`shasum`).
6. Renaming an unlocked locked note then typing keeps the file ciphertext; same after Move To ▸ folder.
7. A note open with unsaved typing: the renamed file contains the typing.
8. Nothing is ever written under `.trash/`.

## Files expected to change

Group B: `Packages/MarkdownKit/Sources/MarkdownKit/{Wikilinks.swift (new), NoteScanner.swift, StyleRanges.swift}`, `Packages/MarkdownKit/Tests/MarkdownKitTests/{WikilinkSyntaxTests.swift (new), NoteScannerTests.swift, SyntaxMarkerTests.swift}`, `Packages/ReadingKit/Sources/ReadingKit/{ReadingBlock, ReadingDocument, ReadingInlineText, ReadingView}.swift`, `Packages/ReadingKit/Tests/ReadingKitTests/ReadingDocumentTests.swift`, `Packages/EditorKit/Tests/EditorKitTests/{RevealScopeTests, ProofingTests}.swift` (pattern updates only), `Packages/IndexKit/Tests/IndexKitTests/{NoteIndexerTests, PipelineIntegrationTests}.swift`, `Packages/VaultKit/Tests/VaultKitTests/VaultFileStoreTests.swift`.
Group C3: `App/Notes/{NotesModel.swift, NotesView.swift, RenameNoteSheet.swift (new)}`, `App/Services/VaultIndexService.swift`, `App/Shell/ShellCommands.swift` (enable `renameNote`).
Must NOT touch: `IndexDatabase.swift` schema, `VaultFileStore.swift`, `VaultTrash.swift`/`Conflicts.swift` (uncommitted nits), `ExportPolicy.swift`, MCPKit.

## Tests

- MarkdownKit `WikilinkSyntaxTests`: one test per grammar row (`parsesPlain`, `parsesAlias`, `parsesHeading`, `parsesHeadingAndAlias`, `parsesBlockId`, `parsesPath`, `trimsTargetAndReportsTargetRange`, `selfHeadingLinkHasEmptyTarget`, `firstPipeSplitsAlias`, `embedIsLink`, `malformedAreNotLinks`, `excludedRangesSkipped`); `rewriteKeepsAliasHeadingPathAndWhitespace`, `rewriteIsCaseInsensitiveOnMatchExactOnReplacement`, `rewriteSkipsSelfHeadingAndExcluded`, `rewriteIsIdempotentAndCountsOnlyChanges`, `rewriteDoesNotTouchOtherTitles` ("Plan" vs "Plans"); `resolvePrefersPathThenSameFolderThenShortestId`, `resolveReturnsNilWhenUnknown`; `anchorLineFindsHeadingCaseInsensitive`, `anchorLineFindsBlockId`, `anchorLineMissingIsNil`.
- `NoteScannerTests.pathQualifiedTargetIndexesTitle`.
- ReadingKit `ReadingDocumentTests.wikilinkAliasRendersLabelAndKeepsTarget`.
- IndexKit `NoteIndexerTests.backlinksFindAliasHeadingAndPathLinks`; `PipelineIntegrationTests.renameCandidatesComeFromBacklinksAndRewriteConverges` (index three notes, run `WikilinkSyntax.rewrite` over `backlinks(toTitle:)` candidates, reindex, assert `backlinks(toTitle: old)` empty and `backlinks(toTitle: new)` == the three).
- VaultKit `VaultFileStoreTests.moveRenamesCaseOnly` (temp dir: `Note.md` → `note.md`; assert the directory lists `note.md` exactly; if the host volume is case-sensitive the test still passes trivially).
- App logic that must live in packages so it is tested: parsing/rewrite/resolve/anchor (MarkdownKit); candidate→rewrite convergence (IndexKit). `NotesModel.rename` ordering is covered by the manual checklist only.

## Regression guard

- Title-sync (`renameToMatchTitle`) still renames on H1 edits; `move(toFolder:)` still works and now re-keys locked notes.
- Trash/Undo, Duplicate, Make Project, Favorites/Pin/Bookmark context items untouched.
- Reading mode checkbox drift guard (`toggleReadingTask`, `:1503-1516`) untouched.
- Proofing exclusions still skip wikilinks (`ProofingTests.imagesAndWikilinksAreExcluded`).
- Linux CI: `Wikilinks.swift` compiles on `swift:6.4-noble` (no AppKit).

## Non-goals

Folder rename/move (Phase 6); rewriting markdown `[text](Old.md)` links; rewriting links inside locked notes; hiding `Note|` in Live mode; renaming from the editor's H1 (title-sync already does that); a rename history; multi-note batch rename; MCP server awareness.

## Builder model

Group B half: sonnet. Group C3 half: **opus** (see "Why opus").

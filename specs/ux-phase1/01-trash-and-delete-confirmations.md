# 01 — Trash, undo-delete, and tag-action confirmations

## Goal

Deleting a note is no longer permanent: the file moves (coordinated) into a hidden `<vault>/.trash/` folder that every reader of the vault already ignores, with an Undo toast and a minimal Trash sheet to restore or purge later. Tag "Remove Tag Everywhere" and "Delete All" ask first.

## Verified findings

- `NotesModel.delete(_:)` (`App/Notes/NotesModel.swift:858-868`) calls `store.delete(at:)` → `FileManager.removeItem` under `.forDeleting` coordination (`Packages/VaultKit/Sources/VaultKit/VaultFileStore.swift:43-47`). No confirmation, no trash. Only caller: the row context menu `Button("Delete", role: .destructive)` at `App/Notes/NotesView.swift:2080`.
- `VaultFileStore.move` (`VaultFileStore.swift:49-57`) coordinates only the **source** URL (`.forMoving`); the destination is not coordinated. Acceptable for the current same-folder renames; the trash move should use the two-URL `coordinate(writingItemAt:options:writingItemAt:options:)` form (see Design).
- Hidden-path exclusion today, by choke point:
  - `VaultEnumerator.snapshot` (`VaultEnumerator.swift:16`): `.skipsHiddenFiles` → a dot-folder and its contents never appear. This feeds `NotesModel.apply` (Mac + iOS initial/refresh), `VaultIndexService.reindexFromDisk` (`VaultIndexService.swift:157`, prunes rows not `present`, `:197-201`) and `deleteStaleIndexFiles` (`:362`). So trashed notes drop out of lists, search, To-Do, and never get an `_index.md`.
  - `MetadataQueryObserver` (`MetadataQueryObserver.swift:58,133-137`): **no hidden filter**; only `_index.md` is dropped. On iOS its snapshots feed `NotesModel.apply` directly (`NotesModel.swift:117-123`). Whether NSMetadataQuery reports items under a dot-folder is **unverified**; the design adds an explicit filter so it does not matter.
  - `ReplicaExporter` (`ReplicaExporter.swift:432-442`): hidden entries skipped, hidden directories never entered (the comment already anticipates `.trash`). `ExportPolicy.pathExclusion` (`ExportPolicy.swift:129-131`) returns `.hiddenPath` for any dot component — second gate. MCP scan fallback `VaultFiles.markdownFiles` (`MCPKit/VaultFiles.swift:35,62`): `.skipsHiddenFiles`.
- Favorites/pinned/bookmarks come from the index (`VaultIndexService.favoriteNoteIds` → `IndexDatabase`), so they clear when the row is pruned; the frontmatter itself travels with the file and comes back on restore. Recents are ids in UserDefaults (`NotesModel.swift:277-285`); `openTabs` are pruned in `apply` (`:188`).
- `delete` calls `performSelect(nil)` first, which awaits the outgoing autosave (`:257-272`); that ordering must be kept. The autosave may title-rename the file (`renameToMatchTitle`), so re-resolve the item by id after the flush.
- Tags: `TagsView.swift:188-196` ("Remove Tag Everywhere") and `:234-243` ("Delete All") call `service.deleteTag` (`VaultIndexService.swift:980-1001`, a regex rewrite of every note) with no confirmation. Plan claim correct.

## Design

### VaultKit: `VaultTrash` (new file `Packages/VaultKit/Sources/VaultKit/VaultTrash.swift`)

```swift
public enum VaultTrash {
    public static let folderName = ".trash"          // Obsidian's convention; hidden everywhere
    public struct Receipt: Sendable, Equatable { public let originalPath: String; public let trashedPath: String }
    public struct Entry: Sendable, Identifiable, Equatable {
        public var id: String { trashedPath }
        public let trashedPath: String      // relative to root, starts with ".trash/"
        public let originalPath: String     // trashedPath with the ".trash/" prefix removed
        public let modificationDate: Date?
    }
    /// Coordinated move of root/relativePath → root/.trash/<same relative path>, uniquified on collision.
    public static func trash(relativePath: String, in root: URL, store: VaultFileStore) async throws -> Receipt
    /// Coordinated move back to originalPath (uniquified if taken). Removes empty .trash subfolders it leaves behind.
    public static func restore(_ entry: Entry, in root: URL, store: VaultFileStore) async throws -> String  // restored relative path
    public static func purge(_ entry: Entry, in root: URL, store: VaultFileStore) async throws     // permanent delete
    public static func empty(in root: URL, store: VaultFileStore) async throws
    /// Enumerates root/.trash directly (so skipsHiddenFiles does not hide the contents), .md files only, newest first.
    public static func list(in root: URL) -> [Entry]
}
```

- Add `VaultFileStore.move(from:to:)` dual-URL coordination (`coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing)`), creating the destination folder first. Existing callers keep working.
- Collision: `VaultNaming.uniqueFileName(base:ext:in:)` → `Note 2.md`.
- Add `VaultPath.isInsideHiddenFolder(_ relativePath: String) -> Bool` (any component **except the last** starts with "."; the last is left alone so `.Note.md.icloud` placeholders are unaffected). Apply it in `MetadataQueryObserver` next to the `isIndexFile` check and in `VaultEnumerator` (belt and braces; `.skipsHiddenFiles` already covers it).

### App

- `NotesModel`: rename `delete(_:)` → `moveToTrash(_:)`. Order: `performSelect(nil)` if loaded (flushes autosave) → re-lookup item by `id` in `notesById` → `VaultTrash.trash` → clear `unlockedKeys[id]` → `apply(snapshot)` → set `lastTrashed: Receipt?` (observable). `undoLastTrash()` restores from the receipt and selects the note. `restore(_ entry:)`, `purge(_:)`, `emptyTrash()`, `trashEntries()` forward to `VaultTrash`.
- `NotesView`: context-menu item becomes "Move to Trash"; on tap a `confirmationDialog("Move “<title>” to Trash?")` with destructive "Move to Trash" (`titleVisibility: .visible`). After the move, a bottom overlay toast "Moved “<title>” to Trash — **Undo**" that auto-dismisses after 6 s (`Task.sleep`, cancelled on Undo or on a newer toast). A `TrashSheet` (new `App/Notes/TrashSheet.swift`): list of `Entry` (title, original folder, date) with Restore, Delete Permanently (confirm), Empty Trash (confirm, shows count). Entry point: a `trash` icon in the Notes sidebar action strip on both platforms (builder: find the strip near `NotesView.swift:730`; if it is macOS-only, add "Trash…" to the iOS Settings › Vault pane instead). No `.toolbar` on detail panes.
- `TagsView`: both tag actions get a `confirmationDialog`: "Remove #tag from N notes?" / "Delete N tags from their notes?" with body "This edits the note text and cannot be undone." N from `service.notesTouchingTag` (make it callable, it exists at `VaultIndexService.swift:985`) or `entry.count`.
- `VaultDebugModel.deleteTestNotes` keeps calling `store.delete` (debug folder, explicit).

## Acceptance criteria

1. Delete on Mac and iPhone asks; confirming moves `Folder/Note.md` to `.trash/Folder/Note.md`; the note leaves the list, search, To-Do, Meetings, Tags counts, Favorites/Pinned and open tabs within one reindex, and `.trash` never gets an `_index.md`.
2. Undo within 6 s restores the file to its original path and reselects it; later restore from the Trash sheet does the same, uniquifying if the name is taken.
3. A trashed note never appears in the remote replica (`ReplicaExporter`) or MCP scan output; `ExportPolicy` returns `.hiddenPath` for `.trash/x.md`.
4. Trashing an open, dirty note first writes the pending text; the trashed file holds the latest keystrokes.
5. Tag actions never rewrite notes without a confirmed dialog.
6. Existing `store.delete` behaviour is unchanged for its remaining callers (import inbox, stale `_index.md`, debug folder).

## Files expected to change

`Packages/VaultKit/Sources/VaultKit/{VaultTrash.swift (new), VaultFileStore.swift, VaultItem.swift, MetadataQueryObserver.swift, VaultEnumerator.swift}`, `Packages/VaultKit/Tests/VaultKitTests/{VaultTrashTests.swift (new), IndexFileExclusionTests.swift}`, `Packages/MarkdownKit/Tests/MarkdownKitTests/ExportPolicyTests.swift` (one case), `App/Notes/{NotesModel.swift, NotesView.swift, TrashSheet.swift (new), TagsView.swift}`.
Must NOT touch: `ExportPolicy.swift` (already correct), `ReplicaExporter.swift`, `MCPKit`, `IndexKit`, `VaultIndexService.swift`, `project.yml`.

## Test plan (VaultKit, Swift Testing, temp-dir vaults)

`VaultTrashTests`: `trashMovesIntoHiddenFolderPreservingSubpath`, `trashUniquifiesOnCollision`, `restoreReturnsToOriginalPath`, `restoreUniquifiesWhenOriginalTaken`, `purgeRemovesOnlyThatEntry`, `emptyRemovesEverything`, `listReturnsMdNewestFirst`, `trashedFileKeepsBytesAndFrontmatter`, `restoreRemovesEmptyTrashSubfolders`, `moveCoordinatesDestination` (move into an existing path replaces it).
`IndexFileExclusionTests`: `enumeratorSnapshotSkipsTrashFolder`, `isInsideHiddenFolderIgnoresPlaceholderFileNames` (`.Note.md.icloud` → false, `.trash/Note.md` → true).
`ExportPolicyTests`: `trashFolderIsHiddenPath`.
Run: `cd Packages/VaultKit && DEVELOPER_DIR=/Applications/Xcode.app swift test --scratch-path ~/.cache/notetaker-build/VaultKit`.

## Non-goals

A Trash browser with previews, auto-empty after N days, trashing folders, swipe-to-delete on iOS, trash for tag edits (they are text rewrites), syncing the Trash sheet's state anywhere (it is a live listing of the folder).

## Risks / invariants

- **Files are truth:** the Trash is just a folder; nothing is stored outside the vault. Undo is a move back, not a cached copy.
- **Exclusion everywhere:** the one new exclusion point is the observer filter; a missed one would show trashed notes on iPhone only. The manual checklist covers it.
- **Autosave race:** keep flush-before-move; never move the `loadedURL` while `dirty`.
- iCloud: the hidden folder syncs like any other; other devices see the note vanish, and the Trash sheet on either device lists the same entries.

## Builder model

sonnet. The only judgement call (flush ordering) is spelled out above.

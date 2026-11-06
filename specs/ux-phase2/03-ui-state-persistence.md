# 03 — UI state across tab switches; last tab and last note at launch

## Goal

Switching tabs no longer wipes the Notes sidebar's state, and on the Mac the app relaunches on the tab and note it was quit on. Nothing new is stored in the vault, and nothing stored is needed to rebuild anything: every key is a hint that is validated against the vault on use.

## Verified findings

- The plan's "Notes UI state resets on every tab switch" is half right. `NotesModel` is owned by `AppShell` (`NotesView.swift:28-30`), so `selectedID`, `openTabs`, `noteText`, `recents` survive. What resets is `NotesView`'s `@State`: `searchText` (`:64`), `selectedTag` (`:71`), `expandedFolders` (`:121`), `tagsExpanded` (`:123`), `showInspector` (`:86`), `listSelection`/`sectionHighlight` (`:117-120`), plus transient sheet flags. Cause: one mounted tab (`AppShell.swift:193-205`), by design.
- No last-note restore: `NotesModel.start()` (`NotesModel.swift:81-150`) applies a snapshot and sets `state = .ready` on four paths (custom root `:86-99`, provisional `:110-114`, iCloud `:117-121`, local fallback `:143-145`) and never selects. `selectedTab` is `@State` (`AppShell.swift:16`).
- Window state restoration is purged on purpose at launch (`NotetakerApp.swift:34-43`), so `@SceneStorage` would be unreliable; use `UserDefaults` (`@AppStorage`) like the existing `recentNotes`, `savedNoteSearches`, `favoriteFolders` keys.
- Trashed notes are excluded from enumeration (`VaultEnumerator` `.skipsHiddenFiles`, Phase 1 spec 01), so a trashed note id is never in `notesById`; `VaultPath.isInsideHiddenFolder` exists (`VaultItem.swift:65`).
- `EditorKit` caches the `NSTextView` across tab switches (`AppShell.swift:191-192`), so the caret/scroll of the open note already survives a tab switch on macOS; across launches it does not. Scroll/caret restore at launch is a non-goal (not cheap: the text is loaded asynchronously and the offset would need validating).

## Design

### Keys (all `UserDefaults.standard`, prefix `ui.`)

| key | type | written | read |
|---|---|---|---|
| `ui.selectedTab` | String | `AppShell` `.onChange(of: selectedTab)` (macOS) | `AppShell` `.task` at first appear (macOS): if the value is in `visibleTabs` ids, set `selectedTab` |
| `ui.notes.lastSelectedNote` | String (note id) | `NotesModel.loadSelection` after a successful load; also when `selectedID` is retargeted in `renameToMatchTitle` (`:484-487`), `move(toFolder:)` (`:853-855`) and spec 05's rename; removed on `performSelect(nil)` | `NotesModel.restoreLastSelection()` (macOS) |
| `ui.notes.expandedFolders` | JSON `[String]` | `NotesView` write-through on change | `NotesView` initial value |
| `ui.notes.inspector` | Bool | `@AppStorage` | `@AppStorage` |

Session-only state that must survive a tab switch but not a relaunch moves into `NotesModel`:

```swift
struct SidebarState: Equatable {
    var searchText = ""
    var selectedTag: String?
    var tagsExpanded = false
    var listSelection: String?
    var sectionHighlight: String?
}
var sidebar = SidebarState()   // on NotesModel
```

`NotesView` replaces the five `@State`s with `model.sidebar.x` (bindings via `Bindable`/`$model.sidebar.searchText` — `NotesModel` is `@Observable`). `expandedFolders` becomes a computed `Set<String>` over a `@AppStorage("ui.notes.expandedFolders") private var expandedFoldersData = "[]"` with a `setExpanded(_:)` helper mirroring `savedSearches`/`favoriteFolders` (`NotesView.swift:79-80`). `showInspector` becomes `@AppStorage("ui.notes.inspector")`.

### Restore (macOS only; `#if os(macOS)` around both)

`NotesModel.restoreLastSelection()` runs once, right after the **first** `state = .ready`/`.readyLocalFallback` assignment in `start()` (all four paths funnel through a `private func markReady(_:)` that calls it the first time). Rules: skip if `selectedID != nil` (the user clicked first); read `ui.notes.lastSelectedNote`; require `!VaultPath.isInsideHiddenFolder(id)` and `notesById[id] != nil` (so trashed, moved, deleted or other-vault notes are simply not restored, and the stale key is removed); then `await performSelect(id)`. A locked note restores to its placeholder (no key in memory) — correct. The iCloud path later replaces the provisional snapshot (`:117-121`); if the note vanished in between, `apply` prunes `openTabs` (`:193`) and the editor shows the "Select a Note" placeholder — acceptable.

`AppShell`: `.task { #if os(macOS) if let saved = UserDefaults.standard.string(forKey: "ui.selectedTab"), visibleTabs.contains(where: { $0.id == saved }) { selectedTab = saved } #endif }` placed before `indexService.start()` in the existing `.task` (`AppShell.swift:109-121`), and `.onChange(of: selectedTab)` writing the key under `#if os(macOS)`. A Release build with a saved `"vault"` falls back to Notes.

### iOS

`SidebarState` moves on both platforms (shared code), so on iPhone the search text and tag filter now survive a tab switch — benign and noted in Decision 5. No tab restore, no note restore, no inspector key use on iOS (the inspector is macOS-only chrome today; keep the `@AppStorage` but it is never shown there). `expandedFolders` persistence applies on iOS too (harmless; the list is shared).

## Acceptance criteria

1. Mac: type in the sidebar search, pick a tag, expand two folders, open the inspector, switch to To-Do and back: all four are as left.
2. Mac: quit on Projects with note X selected; relaunch → Projects; Notes tab shows X open with its text. Trash X (or delete it in Finder) before relaunch → Notes shows no selection, `ui.notes.lastSelectedNote` is cleared, nothing is created.
3. Vault switch (`activeVault` changes, `AppShell` rebuilt): the saved note id from the other vault does not resolve → no selection; no crash.
4. iPhone: launches on Notes with nothing selected exactly as Phase 1; Trash/Undo, To-Do and Tags navigation unchanged.
5. Nothing under the vault folder changes because of this spec (`ls -la <vault>` before/after shows no new file).

## Files expected to change

`App/Shell/AppShell.swift`, `App/Notes/NotesModel.swift`, `App/Notes/NotesView.swift`.
Must NOT touch: packages, `VaultIndexService.swift`, `project.yml`.

## Tests

App-level; no package test can see `NotesModel`. The two validations that matter are pure and already covered: `VaultPath.isInsideHiddenFolder` (Phase 1 `IndexFileExclusionTests`). Add nothing; the manual checklist in the overview is the test.

## Regression guard

- `.onAppear { listSelection = model.selectedID }` (`NotesView.swift:624`) and the `sectionHighlight`/`listSelection` dance in `SelectableTag` (`:2202-2214`) keep their semantics with the state moved; verify clicking a Favorites row highlights that row, not the vault row, and that clicking a vault row clears the section highlight.
- `openDailyNote`, `createNote`, `duplicate` still select the new note (they call `performSelect`, which now also writes the key).
- `recents` behaviour (insert-only, settle delay `:198-207`) untouched.
- Phase 1 trash flow: `moveToTrash` calls `performSelect(nil)` → key cleared; Undo reselects → key written.

## Non-goals

Scroll/caret restore at launch; per-note mode memory (`NotesView.swift:31-33` says per-note memory is deliberate non-goal); window frame restoration (M10); persisting sheet state; iOS restore; `@SceneStorage`.

## Builder model

sonnet.

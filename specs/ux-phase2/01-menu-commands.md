# 01 — Menu bar commands (`.commands`), ⌘1-6, ⌘W

## Goal

Every keyboard shortcut lives in the menu bar and works from every tab. Today most ride on hidden or tab-local buttons that exist only while their view is mounted (one tab is mounted at a time, `AppShell.swift:188-205`). One command table (`ShellCommand`) feeds the menu, the palette (spec 02) and the editor header's ⋯ menu (spec 04), so they cannot drift.

## Verified findings

- No `.commands` anywhere in `App/` (grep). The scene is `WindowGroup { AppShell }.windowStyle(.hiddenTitleBar)` plus a `Task` window group, `Settings` and a `MenuBarExtra` (`App/NotetakerApp.swift:47-86`). No `NSApplicationDelegateAdaptor` exists.
- CLAUDE.md's trap list is about `.toolbar`/`.navigationTitle`/`.searchable`/`.inspector` on detail panes and `.toolbar(.hidden, for: .windowToolbar)`. `.commands` builds `NSMenu`, not `NSToolbar`, and has never been tried under this shell; it is unproven, hence the gated step 1 below.
- Shortcut inventory (macOS), with where each lands:

| shortcut | today | file:line | lives while | new home |
|---|---|---|---|---|
| ⌘K | palette, hidden button in shell background | `AppShell.swift:55-57` | always | Go ▸ Command Palette… (hidden button deleted) |
| ⌘N | New note, sidebar action icon | `NotesView.swift:310-313` | Notes tab | File ▸ New Note |
| ⇧⌘N | Quick Add, To-Do `.toolbar` button | `TodoView.swift:117-128` | To-Do tab | File ▸ New Task… (acts like the ribbon: switch to To-Do + `quickAddSignal += 1`) |
| ⇧⌘D | daily note, hidden button behind the ⋯ sidebar menu | `NotesView.swift:422-426` | Notes tab | File ▸ Today's Daily Note |
| ⌘R | refresh, action icon — **absent while refreshing** (spinner replaces it, `:322-332`) | `NotesView.swift:328-331` | Notes tab | File ▸ Refresh from iCloud |
| ⌘F | find bar, hidden button | `NotesView.swift:1329-1330` | Notes tab, note open, not locked | Edit ▸ Find in Note |
| ⌘E | cycle mode | `NotesView.swift:1331-1332` | same | View ▸ Next Mode |
| ⌘/ | Source↔Live | `:1333-1334` | same | View ▸ Toggle Source |
| ⌘= ⌘- ⌘0 | zoom active mode | `:1337-1342` | same | View ▸ Zoom In / Zoom Out / Actual Size |
| ⌥⌘0 | inspector | `:937-940` | same | View ▸ Show Inspector (checkmark) |
| ⇧⌘P | proofread | `:886-896` | editing modes, LanguageTool configured | Note ▸ Proofread… |
| ⌘B | bold | `:982-986` | editing modes | Format ▸ Bold |
| ⇧⌘I | italic | `:987-991` | editing modes | Format ▸ Italic |
| ⌥⌘C | code | `:997-1001` | editing modes | Format ▸ Code |
| ⇧⌘T | to-do | `:1009-1012` | editing modes | Format ▸ To-Do |
| ⇧⌘K | link | `:1113-1130` | editing modes | Format ▸ Link… |
| ⌃⌥⌘N | system-wide capture, Carbon hotkey | `GlobalHotkey.swift:6-20` | always | unchanged (not a SwiftUI shortcut) |
| ⎋ / ↩ in sheets | `.cancelAction`/`.defaultAction` | `ConflictSheet:28`, `TrashSheet:33`, `NotesView:1158,1170,1751`, `AppShell:379` | sheet | unchanged (sheet-local) |

- Existing signal idiom for cross-view commands: `AppShell` bumps `quickAddSignal`/`newProjectSignal`, the tab view reacts in `.onChange` (`AppShell.swift:331-337`, `TodoView.swift:143-145`, `ProjectsView.swift:36`). The bus below generalises it.
- `AppShell` is recreated on vault switch (`.id(activeVault)`, `NotetakerApp.swift:56`); anything the menu holds must be owned by `NotetakerApp`.
- `NotesView.refreshVault()` (`NotesView.swift:1998-2001`) is `model.refresh()` + `indexService.rescan()`; both objects are available to `AppShell`.

## Design

### `App/Shell/ShellCommands.swift` (new)

```swift
enum ShellCommand: String, CaseIterable, Identifiable {
    // File
    case newNote, newTask, newProject, dailyNote, renameNote /* spec 05 */, closeNote, closeWindow, refreshVault
    // Edit
    case findInNote
    // Format
    case bold, italic, strikethrough, code, headingTitle, headingH2, headingH3, bodyText,
         bulletList, numberedList, todoList, quote, link, insertTable, insertImage, insertRule
    // View
    case nextMode, toggleSourceLive, modeSource, modeLive, modeReading,
         zoomIn, zoomOut, actualSize, focusMode, inspector
    // Note
    case proofread, lockNote, toggleProject, summarize, extractActions, linkGraph, moveToTrash
    // Go
    case goNotes, goTodo, goProjects, goMeetings, goCalendar, goTags, goVault, commandPalette

    var id: String { rawValue }
    var title: String            // menu/palette label, e.g. "New Note", "Today's Daily Note"
    var systemImage: String      // palette icon
    var shortcut: KeyboardShortcut?
    var shortcutLabel: String?   // "⌘N", for palette rows
    enum Scope { case shell, notesTab, openNote, editing }
    var scope: Scope
    func isAvailable(_ bus: ShellCommandBus) -> Bool
}

@MainActor @Observable final class ShellCommandBus {
    /// Published by the surfaces so menu items can enable/disable.
    var notesTabVisible = false
    var hasOpenNote = false      // selectedID != nil && !lockedPlaceholder
    var isEditing = false        // hasOpenNote && editorMode != .reading
    var editorMode: EditorMode = .live
    var languageToolConfigured = false
    /// One-shot request; consumers key `.onChange` on `requestID`.
    private(set) var requestID = 0
    private(set) var pending: ShellCommand?
    func perform(_ command: ShellCommand) { pending = command; requestID += 1 }
}

struct NotetakerCommands: Commands { let bus: ShellCommandBus; var body: some Commands }
```

Shortcuts (exactly these; conflicts with the system defaults are noted): newNote ⌘N — `CommandGroup(replacing: .newItem)`; newTask ⇧⌘N; newProject none; dailyNote ⇧⌘D; renameNote ⌥⌘R (spec 05 wires it; until then the item is present but disabled); closeNote ⌘W and closeWindow ⇧⌘W — `CommandGroup(replacing: .saveItem)` (that group holds the system Close); refreshVault ⌘R; findInNote ⌘F — `CommandGroup(after: .pasteboard)`; bold ⌘B; italic ⇧⌘I; code ⌥⌘C; todoList ⇧⌘T; link ⇧⌘K; strikethrough, lists, headings, quote, inserts: none; nextMode ⌘E; toggleSourceLive ⌘/; modeSource/Live/Reading none (checkmarked by `bus.editorMode`); zoomIn ⌘= ; zoomOut ⌘-; actualSize ⌘0; focusMode none (checkmark from the `editorFocusMode` default); inspector ⌥⌘0 (checkmark); proofread ⇧⌘P; lock/project/AI/graph/trash none; goNotes…goTags ⌘1…⌘6 in the tab order of `AppShell.tabs` (`AppShell.swift:33-41`); goVault ⌘7 `#if DEBUG` only; commandPalette ⌘K.

Menus: **File** (New Note, New Task…, New Project, Today's Daily Note, Rename Note…, —, Close Note, Close Window, —, Refresh from iCloud), **Edit** (system items + Find in Note), **Format** (Heading ▸ Title/Heading/Subheading/Body, —, Bold, Italic, Strikethrough, Code, —, Bullet List, Numbered List, To-Do, Quote, —, Link…, Insert ▸ Table/Image…/Horizontal Rule) as a `CommandMenu`, **View** (Source, Live Preview, Reading as checkmarked items, Next Mode, Toggle Source, —, Zoom In, Zoom Out, Actual Size, —, Focus Mode, Show Inspector) as `CommandMenu("View")` — SwiftUI's default View menu only holds toolbar/sidebar items under this shell; if it already exists use `CommandGroup(after: .sidebar)` instead of a second "View"; **Note** (Proofread…, Summarize Note, Extract Action Items, —, Lock Note / Remove Lock, Make Project / Remove Project Flag, —, Link Graph…, —, Move to Trash…), **Go** (Notes … Tags [, Vault], —, Command Palette…).

Availability: `.disabled(!command.isAvailable(bus))`. `.shell` always; `.notesTab` needs `notesTabVisible` (refreshVault is `.shell`: it works from any tab); `.openNote` needs `hasOpenNote`; `.editing` needs `isEditing`; proofread additionally `languageToolConfigured`. Lock/Project titles flip on `bus.selectedIsLockable`/`bus.selectedIsProject` (add both Bools to the bus; `NotesView` publishes them with the others).

### Wiring

- `NotetakerApp`: `@State private var commands = ShellCommandBus()`; pass to `AppShell(commands:)`; `#if os(macOS)` `.commands { NotetakerCommands(bus: commands) }` on the main `WindowGroup`. iOS: the bus exists (shared `AppShell` signature) but no `.commands` and no behaviour change.
- `AppShell` handles `.shell` scope in `.onChange(of: commands.requestID)`: newNote → `notesModel.createNote(); selectedTab = "notes"`; newTask → `selectedTab = "todo"; quickAddSignal += 1`; newProject → `selectedTab = "projects"; newProjectSignal += 1`; dailyNote → `notesModel.openDailyNote(); selectedTab = "notes"`; refreshVault → `Task { await notesModel.refresh(); await indexService.rescan() }` (and `NotesView.refreshVault` calls the same two lines; leave it); go* → `selectedTab`; commandPalette → `showingPalette = true`; closeWindow → `NSApp.keyWindow?.performClose(nil)`; closeNote → see below. Delete the hidden ⌘K button (`AppShell.swift:53-58`).
- `NotesView` handles `.notesTab`/`.openNote`/`.editing` in its own `.onChange(of: commands.requestID)` (fires only while mounted, which is exactly when they are enabled): findInNote → `findSignal += 1`; nextMode/toggleSourceLive/mode* → `setMode(...)` (keeps the scroll hand-off, `:1380-1395`); zoom* → `zoomActiveMode`/`resetActiveModeZoom`; inspector → `showInspector.toggle()`; focusMode → `focusMode.toggle()`; format commands → the same `EditorCommandRequest` the buttons build (`:982-1050`); link → the `linkButton` action body (`:1114-1124`, factor it into `func linkAction()`); insertImage → `showingImagePicker = true`; proofread → `runProofread()`; lockNote → the lock icon's action (`:905-912`); toggleProject → `:923-925`; summarize/extractActions → `runAI`; linkGraph → `showingGraph = true`; moveToTrash → `trashCandidate = selected item`; renameNote → no-op until spec 05. Publish availability: `.onAppear { commands.notesTabVisible = true }`, `.onDisappear { commands.notesTabVisible = false }`, and `.onChange` of `model.selectedID`, `model.lockedPlaceholder`, `editorMode`, `model.selectedIsLockable`, `languageToolConfigured` writing the bus fields (also once in `.task`).
- Remove the now-duplicated `.keyboardShortcut` modifiers at `NotesView.swift:313, 331, 424 (+ the hidden button 422-426), 895, 940, 986, 991, 1001, 1012, 1130` and the hidden ZStack `:1327-1345`; keep the buttons and their `.help` strings (update the help text that cites a shortcut only if it changes). `TodoView.swift:127`: see overview note.
- **closeNote**: `guard let key = NSApp.keyWindow`. If `key.titleVisibility == .hidden` it is the vault window (only the main `WindowGroup` uses `.hiddenTitleBar`) → if `selectedTab == "notes"`, `let id = notesModel.selectedID` → `notesModel.closeTab(id)` (`NotesModel.swift:818-823`, selects the previous tab or nil); otherwise no-op. If `key.titleVisibility != .hidden` (Task window, Settings) → `key.performClose(nil)`. The builder verifies the heuristic on all three windows at step 1. If Settings or a Task window also reports `.hidden`, do not probe view hierarchies; instead record the vault window's `windowNumber` into the bus (`bus.vaultWindowNumber`) from `AppShell`'s existing window-walk `.task` (`AppShell.swift:126-146`, the first visible window at that moment) and compare numbers.
- `SettingsView.swift:373` caption stays true; add "— all shortcuts are in the menu bar." to it.

### Step 1 — launch proof (separately gated; do this before any other edit in the group)

1. Add `ShellCommands.swift` with the full table but wire **only** Go ▸ Notes…Tags (⌘1-6) and Go ▸ Command Palette (⌘K), via the bus and `AppShell`. No `CommandGroup(replacing:)` yet.
2. Build, then `scripts/verify.sh 1 --install`, then by hand on the installed app. "Launches fine" means **all** of: the process is alive after 8 s (verify's check); the window shows the three traffic lights and the ribbon/tab bar exactly as in Phase 1; the menu bar shows the Go menu; ⌘1…⌘6 switch tabs and ⌘K opens the palette from each of the six tabs; no black or translucent strip appears over any tab's content after switching through all six; opening Settings (⌘,) and a Task Detail window (double-click a task in To-Do) and returning leaves the main window intact; `log stream --process Notetaker --level error` during the above shows no `NSToolbar`, `_insertNewItemWithItemIdentifier` or `NSInternalInconsistencyException` lines; no new file under `~/Library/Logs/DiagnosticReports/Notetaker*` newer than the launch.
3. Pass → add `CommandGroup(replacing: .newItem)` and `CommandGroup(replacing: .saveItem)`, repeat the same check once (replacing system groups is the second-most-likely trigger), then wire the rest.
4. Fail at 2 or 3 → **fallback**: keep `ShellCommand`/`ShellCommandBus`/all dispatch exactly as specified; drop `.commands`; add `App/Shell/MenuBuilder.swift` with an `NSApplicationDelegateAdaptor` whose `applicationDidFinishLaunching` inserts the same menus into `NSApp.mainMenu` with `NSMenuItem(title:action:keyEquivalent:)` targeting a small `@objc` trampoline that calls `bus.perform`. Enable/disable via `NSMenuItemValidation`. Record which variant shipped in PROGRESS. If step 3 alone fails, keep `.commands` without the replacing groups: ⌘N and ⌘W then stay as they are today (hidden button for ⌘N restored, system Close for ⌘W) and the spec's ⌘W behaviour is dropped, noted in PROGRESS.

## Acceptance criteria

1. Every row of the inventory table works from the tab stated in "new home" (shell-scope ones from all six tabs), with the view-mounted duplicate removed.
2. Menu items grey out correctly: Format items in Reading mode and on non-Notes tabs; Note items with no note open or a locked placeholder; Proofread without a LanguageTool URL.
3. ⌘W behaves per Decision 1; the vault window never closes on ⌘W.
4. The launch-proof list in step 1.2 passes on the shipped variant.
5. `ShellCommand.allCases` is the only list of commands; the palette (spec 02) and ⋯ menu (spec 04) build from it.

## Files expected to change

`App/NotetakerApp.swift`, `App/Shell/ShellCommands.swift` (new), `App/Shell/AppShell.swift`, `App/Notes/NotesView.swift`, `App/Shell/SettingsView.swift`, `App/Todo/TodoView.swift` (one line, conditional). Fallback only: `App/Shell/MenuBuilder.swift` (new).
Must NOT touch: `project.yml`, any package, `NotesModel.swift`.

## Tests

The app target has no tests; `ShellCommand` is a data table. Keep logic out of it: `isAvailable` is the only function and it is a pure switch. Everything else is exercised by the manual checklist and the launch proof.

## Regression guard (confirm each after the change)

- One mounted tab (`AppShell.swift:193-205`) unchanged; ribbon buttons (`:321-347`) still work.
- Sheet shortcuts (⎋/↩) in Trash, Conflict, Lock, Link, Proofread sheets unchanged.
- ⌘F still opens the editor's find bar with the editor focused; ⌘E/⌘/ keep the reader's place (the `setMode` hand-off); zoom still targets the active mode's font key.
- iOS build: no `.commands`; the hidden-button removals must not remove iPad hardware-keyboard behaviour the user relies on — none of the removed shortcuts are documented for iOS, so this is accepted.

## Non-goals

Customisable shortcuts; a Window menu beyond the system one; Help menu content; touch bar; Services; opening the palette on iOS.

## Builder model

sonnet. The only judgement call (the launch proof and its fallback) is scripted above.

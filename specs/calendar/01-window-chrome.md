# Spec 01 — Restore the macOS title bar (close / minimize / zoom)

## Scope

macOS only. The main Notetaker window shows the standard traffic-light
buttons in a bar at the top on every tab, with no window title text, no
new toolbar items, and no translucent strip over any in-content header.
iOS is untouched.

## Root cause (proven, not inferred)

Today the main window has **no** close/minimize/zoom buttons and an empty
~52 pt band above the ribbon and tab bar (live screenshot of
`/Applications/Notetaker.app`, 2026-10-29; the Settings window, by contrast,
has all three buttons).

Two views hide the window toolbar on macOS:

- `App/Notes/NotesView.swift` ≈ line 1246: `.toolbar(.hidden, for: .windowToolbar)`
  (inside `#if os(macOS)`, on the detail pane)
- `App/Todo/MeetingsView.swift` ≈ line 179: same modifier on `personPage`

A throwaway SwiftUI app compiled with the Xcode 27 beta toolchain on this
Mac (macOS 27.2) shows what the modifier does to the `NSWindow`:

```
MODE=hidden   (Color + .toolbar(.hidden, for: .windowToolbar))
  _NSThemeCloseWidget      hidden=false
  NSTitlebarView           hidden=false alpha=0.0
  NSTitlebarContainerView  hidden=true          <- the whole title bar, buttons included
  titlebarAppearsTransparent=true
  contentLayoutRect height = window height - 32  <- inset still reserved
MODE=plain    (no modifier)
  NSTitlebarContainerView  hidden=false, buttons drawn
```

With a `NavigationSplitView` inside (the app's real structure) the toolbar
is 52 pt and `.toolbar(removing: .sidebarToggle)` is ignored on this beta —
every split view installs an `NSToolbar` with `toggleSidebar`, so "no
toolbar at all" is not reachable from SwiftUI. The hidden container is
therefore the only reason the buttons are gone; `styleMask` still contains
`.titled/.closable/.miniaturizable/.resizable`, and each button's own
`isHidden` is false (which is why Accessibility lists them as missing but
AppKit says they are fine).

## The fix

Compared three shell layouts (ribbon + top tab bar + nested split view with
an opaque in-content header, like the app) in the same probe:

| variant | traffic lights | title text | header row under the detail column |
|---|---|---|---|
| plain title bar, no hide | yes | yes | **ghosted** — blurred translucent band over the in-content header (the known trap, reproduced) |
| today: `.toolbar(.hidden, for: .windowToolbar)` | **no** | no | crisp, but 52 pt dead band |
| `.windowStyle(.hiddenTitleBar)` on the `WindowGroup`, no hide | **yes** | no | crisp |

So: add `.windowStyle(.hiddenTitleBar)` to the main `WindowGroup` and delete
both `.toolbar(.hidden, for: .windowToolbar)` calls. The 52 pt inset stays
(content is still laid out below `contentLayoutRect`), so no padding changes
in `AppShell` are needed — the ribbon and tab bar keep their positions, and
the band above them now carries the three buttons (and the system's sidebar
toggle item, which is acceptable and not to be fought).

Do NOT: re-add `.toolbar { … }` or `.navigationTitle` to any macOS detail
pane; poke `standardWindowButton(...)`/`NSTitlebarContainerView` from
AppKit (SwiftUI re-applies on every tab mount; fragile); use
`.toolbarBackgroundVisibility` (untested here).

## Changes

1. `App/NotetakerApp.swift` — main `WindowGroup` (the one hosting `AppShell`):

   ```swift
   WindowGroup { … }
       .defaultSize(width: 1150, height: 720)
       #if os(macOS)
       .windowStyle(.hiddenTitleBar)
       #endif
   ```
   `#if` inside the `SceneBuilder` is fine; `windowStyle` is unavailable on
   iOS so it must be conditional. Leave the `task-detail` `WindowGroup` and
   `Settings` scene alone.

2. `App/Notes/NotesView.swift` — remove the macOS `.toolbar(.hidden, for: .windowToolbar)`
   branch; keep the iOS `.navigationTitle` + `.navigationBarTitleDisplayMode(.inline)`
   branch exactly. Rewrite the comment above it: the in-content `editorHeader`
   is still the cure for the strip; the window toolbar is no longer hidden
   because hiding it hides the traffic lights (`NSTitlebarContainerView`);
   the shell's `.windowStyle(.hiddenTitleBar)` keeps the band transparent.

3. `App/Todo/MeetingsView.swift` — same removal on `personPage` (lines ≈176–180),
   comment updated the same way. The `#if os(macOS)` wrapper goes with it.

4. `CLAUDE.md` › Known traps › "macOS beta toolbar bridge": replace the
   clause "and hide the split view's residual toolbar strip" with: the main
   window uses `.windowStyle(.hiddenTitleBar)`; **never** use
   `.toolbar(.hidden, for: .windowToolbar)` — on this beta it hides the
   whole `NSTitlebarContainerView`, traffic lights included (spec
   `specs/calendar/01-window-chrome.md`). Note: `CLAUDE.md` has uncommitted
   user edits on `main`; in a worktree you edit the committed version — the
   merge must keep both.

5. `PROGRESS.md` — one pass row (prefix `FIX:`), stating what was observed in
   the screenshots.

## Acceptance criteria

1. Launch the installed build; screenshot the main window (technique in
   `00-overview.md`). Top-left shows three traffic-light buttons. Repeat on
   every tab reachable from the top tab bar: Notes, To-Do, Projects,
   Meetings, Tags (and Vault in DEBUG) — buttons present on all. Switch
   Notes → To-Do → Notes and re-shoot: still present (the old hide was
   re-applied on every mount; the new state must not flip).
2. No window title text is drawn in the band (`hiddenTitleBar`).
3. Notes tab: the editor header row (format bar + mode picker + action
   cluster) is crisp and fully visible — no blurred/translucent band over
   it. Meetings tab with a person selected: the "Start Meeting" header row
   likewise. Compare against the "plain title bar" ghosting in the probe
   table above; if any ghosting appears, the fix is wrong — stop and
   report, do not patch with `safeAreaInset`/materials.
4. Clicking the yellow button minimizes, the green one zooms (or
   full-screens with ⌥ held), the red one closes the window and ⌘N-style
   reopen via the Dock works — and the window frame clamp in
   `AppShell`'s macOS `.task` still runs (resize a window beyond the
   screen is not required; just confirm no crash at launch).
5. `grep -rn "toolbar(.hidden" App Packages` returns nothing.
6. iOS build green and unchanged in behaviour (no code path changed under
   `#if os(iOS)`).
7. `scripts/verify.sh 3 --install` green.

## Files expected to change

- `App/NotetakerApp.swift`
- `App/Notes/NotesView.swift`
- `App/Todo/MeetingsView.swift`
- `CLAUDE.md` (Known traps paragraph)
- `PROGRESS.md`

Nothing else. If the builder believes another file must change, it should
report why instead of changing it.

## Non-goals

- Moving the tab bar into the title bar / custom traffic-light placement.
- Removing the system sidebar-toggle toolbar item.
- Touching the remaining `.toolbar { items }` on To-Do/Projects/Tags/Vault
  (they render in the band; only report if a screenshot shows them ghosting
  over content).
- Window state restoration (M10).

## Verification commands

```bash
cd ~/Developer/Notetaker
DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Notetaker.xcodeproj -scheme Notetaker \
  -destination 'platform=macOS' -derivedDataPath ~/.cache/notetaker-build/DerivedData build
scripts/verify.sh 1 --install          # during the loop
# screenshot every tab per 00-overview.md; view each PNG with Read
scripts/verify.sh 3 --install          # before the commit; capture the exit code directly, never through a pipe
```

## Builder

**sonnet.** The change is mechanical; the value is in the disciplined
screenshot pass across every tab and in reporting honestly if ghosting
reappears.

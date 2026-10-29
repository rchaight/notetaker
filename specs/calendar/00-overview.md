# Calendar tab + MCP exposure + window chrome — plan overview

User request (2026-10-29, verbatim):

> 1) i would like to add a calendar tab that shows everything on all of my
> calendars as selected in the calendar setting. let's also serve this up
> through MCP (either current claude integration, or other suggestions) so
> that Claude Duet can see my upcoming day and week. 2) on top of the window
> add the bar that has the macOS icons for close window, minimize, and
> expand (red, yellow, green).

Three independently buildable specs live beside this file:

| # | spec | builder | depends on | why |
|---|------|---------|------------|-----|
| 01 | `01-window-chrome.md` — restore the title bar (traffic lights) on macOS | sonnet | — | three-line fix with a proven root cause; the work is the screenshot verification |
| 02 | `02-calendar-tab.md` — `Packages/CalendarKit` (pure model + agenda logic) + Calendar tab in the shell | sonnet | — | pure package with a fixed test list + a UI surface that copies existing in-content patterns |
| 03 | `03-calendar-mcp.md` — opt-in calendar snapshot written by the app, read by `notetaker-mcp` (`calendar_agenda`, `calendar_list`) | sonnet | **02** (CalendarKit model, `CalendarService.snapshot`) | file reader + two tools over an exact JSON contract; privacy field list is fixed by the spec |

## Decisions (with reasoning)

1. **Traffic lights are missing because of `.toolbar(.hidden, for: .windowToolbar)`.**
   Proven with a throwaway SwiftUI app on this machine (macOS 27.2 beta /
   Xcode 27 beta): that modifier is implemented by setting
   `NSTitlebarContainerView.isHidden = true` (title bar view alpha 0), which
   removes the close/minimize/zoom widgets with it while still reserving the
   52 pt title-bar inset — exactly the empty band the live app shows above
   the ribbon. The fix is `.windowStyle(.hiddenTitleBar)` on the main
   `WindowGroup` plus deleting the two hides: in the probe this keeps the
   traffic lights, hides the title text, and does NOT reproduce the ghost
   strip over the in-content header that a plain title bar does. Details and
   the probe transcript are in spec 01.

2. **A new pure package, `Packages/CalendarKit`, owns the calendar model.**
   The snapshot format must be shared by the app (writer) and MCPKit
   (reader), and packages never import the app. MCPKit cannot be the home —
   the app does not link MCPKit (it would drag the MCP SDK into the iOS
   build). CalendarKit is I/O-free like MarkdownKit/TaskEngine: `Codable`
   types, agenda grouping, range resolution, codec. EventKit stays in
   `App/Services/CalendarService.swift` (the only EventKit caller), file
   writes stay in the app, file reads stay in MCPKit.

3. **MCP gets calendar data from an app-written snapshot file, not from
   EventKit directly.** Verified facts about the bundled server binary:
   hardened runtime (`flags=0x10000(runtime)`), entitlements are only
   `application-identifier` + `get-task-allow` (no
   `com.apple.security.personal-information.calendars`), and no embedded
   `__info_plist` section (so no `NSCalendarsFullAccessUsageDescription`).
   EventKit from that process would be refused today. Making it work would
   mean a calendars entitlement + an embedded plist on the tool AND a TCC
   grant attributed to whichever host spawns it (Terminal, Claude Desktop,
   VS Code…) — a prompt per host, surfacing from a headless stdio process
   mid-handshake. That attribution behaviour is Apple-documented but was
   not tested here; it is the main reason to avoid the path. The snapshot
   route reuses the app's one existing grant, works with the app closed
   (dated, with a `stale` flag), and mirrors the index precedent: derived,
   rebuildable, never the source of truth. Trade-off: freshness depends on
   the app having run recently — mitigated by `generated_at`/`stale` in
   every response and by refresh triggers (launch, `EKEventStoreChanged`,
   30-minute timer, toggle on).

4. **Snapshot lives beside the index, not in the vault.**
   `~/Library/Application Support/Index/calendar-snapshot.json` — the
   directory `VaultLocator` already derives for `index.sqlite`. Not in the
   iCloud vault because calendar data is not something the user authors,
   it would sync to every device and show in Finder/Obsidian, and it would
   need another enumeration exclusion. Not in the app-group container
   because `AppGroup.containerURL` is nil on unprovisioned builds.

5. **Sharing is opt-in and field-limited.** Default OFF
   (`calendarShareWithMCP`). When off, the file is deleted and the tools
   answer `available: false` with the Settings path. Exposed fields: title,
   start, end, all-day, calendar title, location, status, organizer name,
   attendee names. Never: event notes/description, URLs, attendee email
   addresses, calendars the user excluded in Settings › Calendar.

6. **Calendar tab = Day/Week agenda list, in-content header, no month grid
   in v1.** A month grid is a different component with its own layout risk
   under the beta toolbar bridge; the agenda list reuses the exact pattern
   Meetings/Notes already use (opaque header + Divider + List). Month can
   come later as a longer agenda.

7. **"Claude Duet" assumption.** Treated as the user's Claude client that
   connects to the same bundled `notetaker-mcp` stdio server as Claude
   Code/Desktop (registered with the `claude mcp add` command from Settings
   or Claude Desktop's MCP settings). If it is a hosted client with no
   access to this Mac's processes, a stdio server cannot reach it; the
   tools still serve Claude Code/Desktop unchanged.

## Ordering, overlap, isolation

- **01 ∥ 02** can run in parallel (worktrees are fine): 01 touches
  `App/NotetakerApp.swift`, `App/Notes/NotesView.swift`,
  `App/Todo/MeetingsView.swift`, `CLAUDE.md`; 02 touches `App/Shell/AppShell.swift`,
  `App/Shell/CommandPalette.swift`, `App/Shell/SettingsView.swift` (one caption
  line), `App/Services/CalendarService.swift`, new `App/Calendar/`,
  new `Packages/CalendarKit`, `project.yml`, `CLAUDE.md` (architecture list).
  The only shared file is `CLAUDE.md` (different paragraphs) and `PROGRESS.md`
  (append-only rows) — trivial merges.
- **03 after 02 is merged.** 03 adds `App/Services/CalendarSnapshotPublisher.swift`,
  a start call in `AppShell`, a Settings › Calendar section, MCPKit sources/tests,
  `Packages/MCPKit/Package.swift`, docs. It overlaps 02 on `AppShell.swift`,
  `SettingsView.swift` (calendar pane), `CalendarService.swift` (uses what 02
  added; should not need to edit it).
- Pre-existing uncommitted changes on `main` (`CLAUDE.md`, `PROGRESS.md`,
  `Packages/ConversionKit/Sources/ConversionKit/PythonEngineConverter.swift`,
  untracked `Notetaker 5.xcodeproj/` — an iCloud duplicate, ignore) belong to
  the user. Builders must not revert or commit them; worktrees branch from
  HEAD and will not contain them.
- Merge each in with `xcodegen generate` + `scripts/verify.sh 3 --install`;
  one commit per spec with its PROGRESS.md row.

## Shared verification technique (window chrome)

Accessibility reports the traffic lights as "missing" even when they are
drawn (verified against the probe), so screenshots are the oracle. List the
app's windows with CGWindowIDs and capture one:

```swift
// winid.swift — compile: DEVELOPER_DIR=/Applications/Xcode-beta.app xcrun swiftc -O winid.swift -o winid
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Notetaker" {
    print(w[kCGWindowNumber as String] ?? 0, "\t", w[kCGWindowName as String] ?? "", "\t", w[kCGWindowBounds as String] ?? [:])
}
```

`screencapture -l <id> -x -o shot.png` then open the PNG with the Read tool
and look at the top-left corner. Put the helper in the session scratchpad,
never in the repo.

## Open questions for the user (none block building)

1. Attendee *names* are shared with Claude by default when sharing is on.
   Prefer names off unless a second toggle is on? (Spec 03 ships one toggle,
   names included.)
2. Calendar tab position: spec 02 puts it after Meetings, before Tags.
3. Does "Claude Duet" run on this Mac with access to local stdio servers?
   If not, the snapshot still exists and a later spec could serve it another
   way; nothing in 03 changes.

## Non-goals (all three)

- Writing to calendars (creating/editing events) from the app or MCP.
- A month grid, drag-to-reschedule, or calendar↔task linking.
- Changing the daily-note `{{meetings}}` output.
- Any change to iOS window chrome; any new window toolbar items on macOS
  (the beta toolbar-bridge trap stands: headers stay in-content).
- Serving calendar data over HTTP, XPC, or a second MCP transport.

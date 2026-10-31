# Spec 03 — Calendar through `notetaker-mcp` (opt-in snapshot)

Depends on spec 02 being merged (`CalendarKit`, `CalendarService.snapshot`).

## Scope

When the user turns on **Settings › Calendar › "Share upcoming events with
the MCP server"**, the app keeps a derived JSON snapshot of the included
calendars' events (yesterday → 28 days ahead) beside the index, and the
bundled read-only `notetaker-mcp` server gains two tools over it:
`calendar_agenda` and `calendar_list`. Off by default; off deletes the file
and the tools say so. Claude Code, Claude Desktop and "Claude Duet" (assumed
to be a client of the same stdio server — see `00-overview.md` §7) all get
it through the existing `claude mcp add notetaker -- "<path>"` registration;
nothing new to register.

## Why a snapshot and not EventKit in the server

Verified on the installed build (`codesign -d --entitlements -`, `otool -s
__TEXT __info_plist`): `notetaker-mcp` runs under the hardened runtime with
only `application-identifier` and `get-task-allow`, and has no embedded
Info.plist. EventKit from it is refused as built. Enabling it would need
`com.apple.security.personal-information.calendars` on the tool, an
embedded `NSCalendarsFullAccessUsageDescription`, and — the real cost — a
TCC calendar grant attributed to whichever process spawns the server
(Terminal, Claude Desktop, VS Code…): one prompt per host, appearing from a
headless process during the MCP handshake, and a second calendar-access
grant the user has to reason about. That attribution behaviour is
documented by Apple but was not exercised here; the snapshot route avoids
it entirely, reuses the app's single existing grant, and works while the
app is closed (with an explicit `stale` flag). It also matches the index
precedent: a derived, rebuildable file that is never the source of truth.
Trade-off accepted: freshness depends on the app having run recently.

## Design

### Snapshot file (app-owned, derived)

- Path: `<Application Support>/Index/calendar-snapshot.json` — the same
  directory `VaultIndexService` uses for `index.sqlite` and `VaultLocator`
  already derives (`applicationSupport/Index`). One file per machine,
  independent of the active vault.
- Content: `CalendarKit.CalendarSnapshot` encoded with `SnapshotCodec.encode`.
  Range: `[startOfDay(now − 1 day), startOfDay(now + 28 days))`. Included
  calendars only (Settings exclusions applied inside
  `CalendarService.snapshot`). Fields are exactly `CalendarEvent`'s — no
  notes, URLs or emails exist in the model, so nothing extra can leak.
- Written atomically (`Data.write(to:options: .atomic)`) by a new
  `App/Services/CalendarSnapshotPublisher.swift` (`@MainActor final class`,
  owned by `AppShell` as `@State`, macOS only — `#if os(macOS)` around the
  whole file and its call sites; the server is macOS-only). Not VaultKit:
  this is app cache outside the vault, same as `publishWidgetSnapshot`.
- Triggers (all no-ops unless `calendarShareWithMCP` is true AND access is
  granted): `start()` from `AppShell`'s existing macOS `.task`; every
  `.EKEventStoreChanged` notification (debounced 2 s); a 30-minute repeating
  timer (covers midnight rollover); the toggle flipping to on. The toggle
  flipping to off, or `start()` finding it off, deletes the file if present.
  Compare-before-write: skip the write when the encoded bytes equal the
  current file's (keeps mtime meaningful; same idea as `_index.md`).
- Failures (no access, encode/write error) log via `os.Logger` and leave the
  previous file untouched; never crash.

### Settings › Calendar (`SettingsView.swift`, calendar pane only)

New `Section("Claude / MCP")` below "Included calendars", macOS only:

- `Toggle("Share upcoming events with the MCP server", isOn: $calendarShareWithMCP)`
  (`@AppStorage("calendarShareWithMCP") = false`). Disabled with a caption
  when access is not granted.
- Caption (on): "Notetaker keeps a local snapshot of the next four weeks —
  title, time, calendar, location, status, organizer and attendee names —
  at `<path>` for the read-only notetaker-mcp server. Event notes, links and
  email addresses are never included. Turn this off to delete the snapshot."
- Caption (off): "Off — Claude cannot see your calendar."
- A `LabeledContent("Last snapshot")` showing the file's mtime (or "none"),
  refreshed on appear.
- A short line in the existing AI & Import "Claude integration" caption:
  "Calendar access for the MCP server is a separate toggle in Settings › Calendar."

### MCPKit

- `Packages/MCPKit/Package.swift`: add `.package(path: "../CalendarKit")` and
  the `CalendarKit` dependency on both targets.
- `VaultLocation` gains `public let calendarSnapshotPath: String?`;
  `VaultLocator.resolve` fills it with `<indexDirectory>/calendar-snapshot.json`
  (the same `indexDirectory` it already computes), overridable by
  `--calendar <path>` (tests, parity with `--index`). It is always a path —
  make it non-optional (`String`); absence of the file is handled by the
  reader, not by the locator.
- New `Sources/MCPKit/VaultCalendar.swift`: `extension VaultService` with

  ```swift
  struct CalendarAgendaQuery: Sendable {
      var range: String?        // "today" | "tomorrow" | "week" | "custom"; default "today"
      var from: String?         // yyyy-mm-dd, custom only
      var to: String?           // yyyy-mm-dd, custom only, inclusive
      var calendar: String?     // case-insensitive calendar title filter
  }
  func calendarAgenda(_ query: CalendarAgendaQuery, now: Date = Date(), calendar: Calendar = .current) -> Value
  func calendarList() -> Value
  ```

  Both load the file fresh on every call (no caching — the app may rewrite
  it at any time); decode with `SnapshotCodec.decode`. Range → `AgendaRange`:
  `today` = `.day(now)`, `tomorrow` = `.day(now + 1 day)`, `week` =
  `.week(from: now)` (today + 6 days), `custom` requires `from`/`to` else
  `MCPError.invalidParams`. `AgendaBuilder.days` does the grouping.

- Response shapes (JSON via the existing `json(_:)`, also as
  `structuredContent`):

  `calendar_agenda`, available:
  ```json
  {
    "available": true,
    "source": "snapshot",
    "generated_at": "2026-10-29T13:05:00Z",
    "snapshot_age_minutes": 12,
    "stale": false,
    "time_zone": "America/Chicago",
    "range": { "from": "2026-10-29", "to": "2026-11-04" },
    "coverage_note": null,
    "days": [
      { "day": "2026-10-29", "weekday": "Wednesday", "is_today": true,
        "events": [
          { "id": "…", "title": "1:1 Robert & Amber", "start": "2026-10-29T10:30:00-05:00",
            "end": "2026-10-29T11:20:00-05:00", "all_day": false, "calendar": "Work",
            "location": "Teams", "status": "confirmed", "organizer": "Amber Smallwood",
            "attendees": ["Robert Haight", "Amber Smallwood"] }
        ] }
    ]
  }
  ```
  `stale` = age > 6 h. `coverage_note` is a string when the requested range
  extends past `[rangeStart, rangeEnd)` of the snapshot ("Snapshot covers
  2026-10-28 … 2026-11-26; days outside it are shown empty.") else null.
  `start`/`end` are ISO 8601 with the snapshot's time-zone offset
  (`ISO8601DateFormatter` with `timeZone` set from `time_zone`); `day` keys
  use that zone too. `location`/`organizer` are `null` when absent;
  `attendees` is `[]` when none.

  Not available (file missing, undecodable, sharing off):
  ```json
  { "available": false,
    "reason": "Calendar sharing is off. Turn on Settings › Calendar › \"Share upcoming events with the MCP server\" in Notetaker.",
    "source": "snapshot" }
  ```
  (`isError: false` — it is an answer, and the model should relay the
  instruction.) An undecodable file reports `reason: "snapshot unreadable (<error>) — open Notetaker to regenerate it"`.

  `calendar_list`: `{ "available": true, "generated_at": …, "stale": …, "calendars": [ { "id", "title", "account", "color" } ] }` or the same unavailable shape.

- `NotetakerMCPServer.tools()`: two new `Tool`s with the read-only
  annotations. Descriptions written for the model, e.g. `calendar_agenda`:
  "The user's upcoming calendar events from the calendars they chose to
  share with you, grouped by day. Use it for 'what's on today / this week /
  on Friday', meeting prep, and finding free time. Default range is today;
  'week' is today plus the next six days; 'custom' takes from/to dates.
  Events come from a snapshot Notetaker refreshes while it runs — check
  `stale` and `generated_at`. Returns `available: false` with instructions
  when the user has not turned sharing on." `calendar_list`: "The calendars
  included in the shared snapshot, with account and colour. Use the titles
  as the `calendar` filter for calendar_agenda."
- `call(name:…)`: dispatch `calendar_agenda` / `calendar_list`.
- `instructions`: add one sentence: "calendar_agenda shows the user's day
  or week when they have enabled calendar sharing; it is a snapshot, so
  check `stale`."
- `NotetakerMCPLauncher.usage`: list the new tools and `--calendar <path>`.

### Tests (MCPKit, Swift Testing)

Fixture: write a `CalendarSnapshot` (built in code, encoded with
`SnapshotCodec`) to a temp path; construct `VaultLocation` with
`calendarSnapshotPath` pointing at it (extend `VaultFixture` with
`service(withIndex:calendar:)` or a `calendarSnapshotPath` parameter).
Fixed `now` and `Calendar` with `America/Chicago`.

1. `today` returns only today's events; `tomorrow` only tomorrow's;
   `week` returns 7 `days` entries including empty ones.
2. `custom` with `from`/`to` inclusive; missing `to` → `isError: true`
   with "to is required" (through `NotetakerMCPServer.call`).
3. `calendar` filter is case-insensitive and drops other calendars.
4. `stale` is false at age 5 min, true at age 7 h; `snapshot_age_minutes`
   is computed from `generated_at` vs `now`.
5. `coverage_note` is non-null when the custom range ends after
   `rangeEnd`; null otherwise.
6. Missing file → `available: false` with the Settings instruction;
   `isError: false`. Garbage file → `available: false` with "unreadable".
7. The encoded response's key set for an event is exactly
   `{id,title,start,end,all_day,calendar,location,status,organizer,attendees}`
   (privacy contract pinned structurally).
8. `calendar_list` returns the fixture's calendars with `color`.
9. `ProtocolSmokeTests.initializeListAndCallOverATransport`: the sorted tool
   list now has 7 names, both new tools carry `readOnlyHint == true` and a
   description > 80 characters.
10. `VaultLocatorTests`: `--calendar` override honoured; default path is
    `<indexDirectory>/calendar-snapshot.json`.

### Docs

- `FEATURES.md` §3.5: a bullet under the MCP item: calendar tools, opt-in,
  snapshot semantics, field list, "never notes/links/emails".
- `README.md` MCP paragraph: one sentence on the Settings › Calendar toggle.
- `CLAUDE.md`: in the MCPKit line add "+ opt-in calendar snapshot tools";
  the snapshot path in Known traps is not needed (it is not a trap).
- `PLAN.md` M9.9: a bullet. `PROGRESS.md`: pass row.

## Acceptance criteria

1. MCPKit `swift test` green (existing 33 + the tests above); passes 3× in
   the gate.
2. With sharing OFF (default): `calendar-snapshot.json` does not exist (or
   is deleted on launch if it did); `calendar_agenda` over stdio returns
   `available: false` with the Settings instruction. Builder demonstrates
   with the transcript below.
3. Toggle ON in Settings: within a few seconds the file exists, contains
   `"schemaVersion": 1`, no key `notes`/`url`/`email` anywhere
   (`grep -c '"notes"' …` = 0), and only included calendars' events
   (toggle a calendar off in Settings → after `EKEventStoreChanged`/timer
   or a relaunch, its events are gone — relaunch is acceptable).
4. With the app CLOSED, `calendar_agenda {"range":"week"}` over stdio
   returns 7 days from the file with `stale` reflecting its age; with the
   app open and an event added in Calendar.app for today, a re-call within
   ~5 s shows it.
5. Toggle OFF → file deleted; tool returns `available: false` again.
6. Locked notes and every existing tool unchanged (existing tests green).
7. iOS build green (publisher and Settings section compiled out).
8. `scripts/verify.sh 3 --install` green; launch OK.

Stdio transcript (run with the app closed, after `scripts/verify.sh 1 --install`):

```bash
MCP=/Applications/Notetaker.app/Contents/MacOS/notetaker-mcp
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
READY='{"jsonrpc":"2.0","method":"notifications/initialized"}'
CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"calendar_agenda","arguments":{"range":"week"}}}'
( printf '%s\n' "$INIT" "$READY" "$CALL"; osascript -e 'delay 3' ) | "$MCP" 2>/dev/null | tail -1 | head -c 4000
```
(`osascript -e 'delay 3'` because a foreground `sleep` is blocked in this
harness.) If piping is awkward, the in-process `ProtocolSmokeTests` covers
the protocol path and the builder states that the stdio run was replaced.

## Files expected to change

- new `App/Services/CalendarSnapshotPublisher.swift`
- `App/Shell/AppShell.swift` (own + start the publisher, macOS `.task`)
- `App/Shell/SettingsView.swift` (calendar pane section; one AI & Import caption line)
- `Packages/MCPKit/Package.swift`
- `Packages/MCPKit/Sources/MCPKit/{VaultLocation,NotetakerMCPServer,NotetakerMCPLauncher}.swift`
- new `Packages/MCPKit/Sources/MCPKit/VaultCalendar.swift`
- `Packages/MCPKit/Tests/MCPKitTests/{VaultFixture,VaultLocatorTests,ProtocolSmokeTests}.swift`, new `VaultCalendarTests.swift`
- `FEATURES.md`, `README.md`, `CLAUDE.md`, `PLAN.md`, `PROGRESS.md`
- `project.yml` only if a new package link is needed (it should not be — MCPKit links CalendarKit via SwiftPM, the app already links it from spec 02)

Must not change: `CalendarService.swift` (if something is missing there,
report it — spec 02 owns it), any vault file handling, `VaultService` init
signature beyond the location field, `~/.claude.json` or any Claude config.

## Non-goals

- EventKit access from the server process; any entitlement change to
  `NotetakerMCP`.
- Free/busy computation, event creation, RSVP, or write tools.
- Serving the snapshot through MCP resources, HTTP, or the widget.
- Per-field toggles (one on/off switch in v1; see overview open question 1).
- iOS (the server is macOS-only; the Calendar tab from spec 02 covers iOS).

## Verification commands

```bash
cd ~/Developer/Notetaker/Packages/MCPKit && DEVELOPER_DIR=/Applications/Xcode.app \
  swift test --scratch-path ~/.cache/notetaker-build/MCPKit
cd ~/Developer/Notetaker && xcodegen generate && swiftformat --lint .
scripts/verify.sh 1 --install          # loop
# stdio transcript above, off and on; `ls -la ~/Library/Application\ Support/Index/`
scripts/verify.sh 3 --install          # before commit; exit code captured directly
```

## Builder

**sonnet.** The JSON contract, range semantics, privacy key set and tests
are fully pinned; the publisher follows `publishWidgetSnapshot` and the
`_index.md` compare-before-write precedent. Escalate to **opus** only if the
publisher's lifecycle (notification loop + timer + toggle) proves racy under
the gate's 3× runs.

# Spec 02 — `Packages/CalendarKit` + Calendar tab

## Scope

A new **Calendar** tab (macOS + iOS) showing every event from the calendars
the user left included in Settings › Calendar, as a Day or Week agenda,
with prev/next/today navigation and a jump to that day's daily note. The
data model, agenda grouping and range arithmetic live in a new pure package
so spec 03 (MCP) can share the exact same types without importing the app.

Existing behaviour that must not change: daily-note `{{meetings}}`
generation (`CalendarService.meetingsMarkdown`), the Settings include/
exclude list and its `excludedCalendarIds` key, the permission flow.

## Design

### `Packages/CalendarKit` (new, pure — no Foundation I/O, no EventKit)

`Package.swift` mirrors TaskEngine: `swift-tools-version: 6.0`, platforms
`.macOS("26.0"), .iOS("26.0")`, one library target `CalendarKit`, test
target `CalendarKitTests` (Swift Testing, like the other packages). Add it
to `project.yml` `packages:` and to the `Notetaker` target dependencies;
regenerate with `xcodegen generate`.

Types (all `public`, `Sendable`, `Codable`, `Equatable`):

```swift
public struct CalendarInfo: Identifiable {
    public let id: String          // EKCalendar.calendarIdentifier
    public let title: String
    public let account: String     // EKSource.title
    public let colorHex: String?   // "#RRGGBB", sRGB
}

public struct CalendarEvent: Identifiable {
    /// "<eventIdentifier>@<start unix seconds>" — eventIdentifier is shared by
    /// every occurrence of a recurring event, so the start disambiguates.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let calendarId: String
    public let calendarTitle: String
    public let calendarColorHex: String?
    public let location: String?
    public let status: Status      // enum String: none, confirmed, tentative, canceled
    public let organizer: String?  // display name only
    public let attendees: [String] // display names only, source order
    // Deliberately absent: notes/description, URL, attendee emails.
}

public struct CalendarSnapshot {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let generatedAt: Date
    public let rangeStart: Date
    public let rangeEnd: Date       // exclusive
    public let timeZone: String     // TimeZone.identifier at generation
    public let calendars: [CalendarInfo]   // included calendars only
    public let events: [CalendarEvent]     // sorted by start, then title
}

public enum SnapshotCodec {
    /// JSONEncoder: .iso8601 dates, .sortedKeys, .prettyPrinted, .withoutEscapingSlashes.
    public static func encode(_ snapshot: CalendarSnapshot) throws -> Data
    /// Throws `SnapshotError.unsupportedSchema(found:)` when schemaVersion > supported.
    public static func decode(_ data: Data) throws -> CalendarSnapshot
}

public enum AgendaRange: Equatable, Sendable {
    case day(Date)           // the calendar day containing the date
    case week(from: Date)    // 7 calendar days starting at that day
    case custom(from: Date, to: Date)  // inclusive days
    /// Half-open [start, end) in `calendar`, both at startOfDay.
    public func bounds(calendar: Calendar) -> (start: Date, end: Date)
}

public struct AgendaDay: Identifiable, Equatable, Sendable {
    public var id: String { day }
    public let day: String           // "yyyy-MM-dd" in `calendar`'s time zone
    public let date: Date            // startOfDay
    public let events: [CalendarEvent]
}

public enum AgendaBuilder {
    /// One AgendaDay per calendar day in [start, end), in order, empty days
    /// included. An event appears on every day it overlaps (multi-day and
    /// midnight-crossing events repeat; all-day events that EventKit ends at
    /// 23:59:59 do not spill into the next day — treat `end` as exclusive
    /// and clamp all-day ends to startOfDay(end)). Within a day: all-day
    /// first (title order), then by start, then title, then id.
    public static func days(events: [CalendarEvent], range: AgendaRange, calendar: Calendar) -> [AgendaDay]

    /// The events overlapping [start, end) — used by the snapshot writer and
    /// by the MCP range filter. Same overlap rule as above.
    public static func events(_ events: [CalendarEvent], overlapping start: Date, _ end: Date) -> [CalendarEvent]
}

public enum DayKey {
    /// "yyyy-MM-dd" with en_US_POSIX, in `calendar.timeZone`.
    public static func string(for date: Date, calendar: Calendar) -> String
    public static func date(from key: String, calendar: Calendar) -> Date?
}
```

Required tests (`Tests/CalendarKitTests`, Swift Testing, a fixed
`Calendar(identifier: .gregorian)` with `TimeZone(identifier: "America/Chicago")`
and a fixed `now` so results are deterministic):

1. Codec round-trip: encode → decode equals the original, dates to the
   second; encoding is byte-stable across two calls (sorted keys).
2. Decoding `{"schemaVersion": 99, …}` throws `unsupportedSchema`.
3. Encoded JSON contains no key named `notes`, `url`, or `email` (guards the
   privacy contract structurally).
4. `AgendaRange.day` on 2026-03-08 (DST start in Chicago) yields a 23-hour
   bound pair; `.week(from:)` yields exactly 7 days; `.custom` is inclusive.
5. `days`: an event 23:30–00:30 appears on both days; a 3-day all-day
   event appears on exactly 3 days; an all-day event ending at 23:59:59 of
   its last day does not appear on the following day.
6. Ordering inside a day: all-day before timed, then start, then title.
7. Empty days are present with `events == []` for a week with one event.
8. `events(_:overlapping:)` excludes an event ending exactly at `start` and
   includes one starting exactly at `start`.
9. Two occurrences of the same recurring event (same `eventIdentifier`,
   different starts) have different `id`s and both survive grouping.

### App: `CalendarService` additions (`App/Services/CalendarService.swift`)

Keep the existing API. Add:

```swift
/// Included calendars (every event calendar minus the excluded set).
static func includedCalendars(excludedCalendarIds: Set<String> = excludedCalendarIds()) -> [CalendarInfo]

/// Events overlapping [start, end) across the included calendars, mapped to
/// CalendarKit's model. Empty when access is not granted.
static func events(from start: Date, to end: Date,
                   excludedCalendarIds: Set<String> = excludedCalendarIds()) -> [CalendarEvent]

/// A snapshot for [startOfDay(today - daysBack), startOfDay(today + daysAhead)).
static func snapshot(daysBack: Int, daysAhead: Int, now: Date = Date(),
                     calendar: Calendar = .current) -> CalendarSnapshot
```

Mapping rules (EventKit → `CalendarEvent`): `title ?? "Untitled event"`;
`status`: `.confirmed/.tentative/.canceled/.none` → the enum; `organizer?.name`;
`attendees?.compactMap(\.name)`; `location` trimmed, empty → nil;
`calendar.cgColor` → hex via
`cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components`
(nil if conversion fails). `id = "\(eventIdentifier ?? UUID().uuidString)@\(Int(startDate.timeIntervalSince1970))"`.
Use `predicateForEvents(withStart:end:calendars:)` with the included
calendars (empty included list → return `[]`, don't pass an empty array —
EventKit treats nil as "all"). The daily-note `meetings(on:)` path may be
re-expressed on top of `events(from:to:)` only if its output stays
byte-identical for the same day; otherwise leave it.

### App: `App/Calendar/CalendarView.swift` (new)

Single-pane view (no `NavigationSplitView` — nothing to split, and every
split view installs a toolbar on this beta). Structure, following the
pattern in `MeetingsView.personPage` / `NotesView.editorHeader`:

```
VStack(spacing: 0) {
    header   // opaque Color.headerBackground, padding 10/16, then Divider()
    content  // List, or ContentUnavailableView states
}
```

- `header`: `[‹] [Today] [›]` buttons (`chevron.left`, `chevron.right`),
  a `Picker` (segmented) **Day | Week** bound to `@AppStorage("calendarTabRange")`
  (`"day"` default `"week"`), the title text (Day: "Wednesday, October 29";
  Week: "Oct 27 – Nov 2, 2026", via `Date.FormatStyle`), `Spacer()`, a
  `Button("Daily Note", systemImage: "note.text")` that calls
  `openDailyNote(anchorDate)` (Day mode) / the first day of the week (Week
  mode). No keyboard shortcuts in v1 (the editor already owns most ⌘
  combinations); `.help` tooltips on every button.
- `content` by `CalendarService.accessState()`:
  - `.notRequested`: `ContentUnavailableView("Connect Your Calendars", systemImage: "calendar.badge.plus", …)`
    with a "Connect Calendars…" button → `await CalendarService.requestAccess()` then reload.
  - `.denied`: unavailable view pointing to System Settings › Privacy & Security › Calendars.
  - `.granted` and no included calendars: unavailable view "No calendars included — pick them in Settings › Calendar".
  - `.granted`: `List` with one `Section` per `AgendaDay` (header: "Today · Wed, Oct 29", "Tomorrow · …", else "Thu, Oct 30"). Rows:
    `HStack(spacing: 10)`: a 3 pt × 28 pt `RoundedRectangle` filled with the calendar colour (fallback `.accentColor`); a 96 pt-wide trailing-aligned time column with `.monospacedDigit()` ("All day" or "9:00 – 9:45 AM" using `Date.FormatStyle(time: .shortened)`); `VStack(alignment: .leading)` title (`.body`, strikethrough + secondary when `status == .canceled`) and an optional secondary line `location` / `calendarTitle`. The event containing `now` gets `.fontWeight(.semibold)` and a `Color.accentColor.opacity(0.08)` row background. Empty day in Week mode: one secondary "No events" row. Row tap toggles an inline disclosure (`@State var expanded: Set<String>`) that shows organizer, attendees (comma-joined), calendar + account, status — no popovers, no sheets needed.
- State: `@State anchor: Date` (startOfDay today), `@State events: [CalendarEvent]`, `@State days: [AgendaDay]`. Load with `CalendarService.events(from:to:)` for the current `AgendaRange` then `AgendaBuilder.days` — off the main actor is unnecessary (EventKit calls are fast for a week). Reload on: appear, anchor/range change, `NotificationCenter.default.notifications(named: .EKEventStoreChanged)` (a `.task` for-await loop), and `scenePhase == .active`.
- iOS: wrap in `NavigationStack` with `.navigationTitle("Calendar")` under `#if os(iOS)` only; the in-content header stays on both platforms.

### App: shell wiring

- `AppShell.swift`: add `("calendar", "Calendar", "calendar")` to `tabs`
  after `meetings`; `case "calendar": calendarTab` in `mountedViews`; an iOS
  `Tab("Calendar", systemImage: "calendar", value: "calendar")` in the same
  position; `private var calendarTab: some View { CalendarView(openDailyNote: { date in notesModel.openDailyNote(for: date); selectedTab = "notes" }) }`.
- `CommandPalette.swift`: append `("Calendar", "calendar")` to the "Go to"
  tuple array (leave the existing three entries as they are).
- `SettingsView.swift` calendar pane: the `.granted` label text becomes
  "Connected — meetings populate new daily notes and the Calendar tab".
  Nothing else in Settings (spec 03 owns the sharing section).
- `project.yml`: `NSCalendarsFullAccessUsageDescription` → "Notetaker reads
  your calendars to show them in the Calendar tab and list the day's
  meetings in daily notes. Nothing leaves the device unless you turn on
  sharing with the MCP server in Settings." then `xcodegen generate`
  (regenerates `App/Info.plist`; commit it like 6df5806 did).
- `CLAUDE.md` Architecture list: add
  `Packages/CalendarKit — calendar snapshot model, agenda grouping, range arithmetic. Pure; no I/O; EventKit stays in App/Services/CalendarService.`
  and under App: `Calendar/ — the Calendar tab`.

## Acceptance criteria

1. `swift test` in `Packages/CalendarKit` green with at least the nine tests
   above; the suite passes 3× in `scripts/verify.sh 3`.
2. macOS: Calendar tab appears in the top tab bar after Meetings; switching
   to it and back is instant with no layout shift of the ribbon/tab bar.
   Screenshot (technique in `00-overview.md`) shows the in-content header,
   a Week agenda with day sections, coloured calendar bars, and — with
   spec 01 merged — the traffic lights; without it, the same empty band
   every other tab has today. No translucent strip over the header.
3. Toggling a calendar off in Settings › Calendar and returning to the tab
   removes its events (reload on appear); turning it back on restores them.
4. An event created in Calendar.app for today appears within a few seconds
   without switching tabs (`EKEventStoreChanged`).
5. "Daily Note" opens/creates `Daily/<yyyy-MM-dd>.md` for the shown day and
   switches to Notes; the daily-note template output for today is unchanged
   (diff a freshly created daily note against one created before the change
   on a day with events — identical `{{meetings}}` block).
6. iOS Simulator build green; the Calendar tab shows in the adaptive
   TabView (build only — no simulator run required).
7. `scripts/verify.sh 3 --install` green; launch check OK.
8. Not required but reported honestly: whether the builder observed the UI
   live (the user's daily shakedown is the fallback, as with earlier passes).

## Files expected to change

- new `Packages/CalendarKit/Package.swift`, `Sources/CalendarKit/{CalendarModel,SnapshotCodec,Agenda}.swift`, `Tests/CalendarKitTests/*.swift`
- new `App/Calendar/CalendarView.swift`
- `App/Services/CalendarService.swift`
- `App/Shell/AppShell.swift`, `App/Shell/CommandPalette.swift`, `App/Shell/SettingsView.swift` (one string)
- `project.yml` (+ regenerated `Notetaker.xcodeproj`, `App/Info.plist`)
- `CLAUDE.md` (architecture lines), `PROGRESS.md` (pass row), `PLAN.md` (a new M9.9 bullet under the shakedown section: Calendar tab)

## Non-goals

- Month grid / timeline / week columns. Drag, edit, create events.
- A Calendar surface in the widget or App Intents.
- Writing any file (spec 03 owns the snapshot publisher).
- Reading event notes/URLs into the model.
- Changing the ribbon's daily-note button or its icon.

## Verification commands

```bash
cd ~/Developer/Notetaker/Packages/CalendarKit && DEVELOPER_DIR=/Applications/Xcode.app \
  swift test --scratch-path ~/.cache/notetaker-build/CalendarKit
cd ~/Developer/Notetaker && xcodegen generate && swiftformat --lint .
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -project Notetaker.xcodeproj -scheme Notetaker \
  -destination 'platform=macOS' -derivedDataPath ~/.cache/notetaker-build/DerivedData build
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -project Notetaker.xcodeproj -scheme Notetaker \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/.cache/notetaker-build/DerivedData build CODE_SIGNING_ALLOWED=NO
scripts/verify.sh 3 --install
```

## Builder

**sonnet.** The package has a fixed test list and no I/O; the view copies
an established in-content pattern. The only judgement call (multi-day /
all-day overlap rules) is pinned down above.

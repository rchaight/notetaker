# 02 — One completion engine: every checkbox stamps ✅ identically

## Goal

Checking a task in the editor (Mac or iOS), in Reading mode, in the To-Do list, Logbook, Meetings, Projects or a widget produces the same source line: non-recurring → `[x] … ✅yyyy-mm-dd`; unchecking strips the stamp; recurring → `[ ]` with the next `>date` (existing `RecurrenceTests`). One line-level primitive, in one package, called by every surface.

## Verified findings

- **Editor path:** `MarkdownEditor.swift:1090-1107` (macOS `clickedOnLink`) and `:1651-1659` (iOS `handleCheckboxTap`) call `RecurrenceEngine.completeTask(in:tokenRange:)` → `completeTaskLine` (`Packages/TaskEngine/Sources/TaskEngine/Recurrence.swift:143-172`), whose non-recurring branch is `flipCheckbox` only (`:150`, `:210-225`). **No ✅ stamp.** Plan claim correct. The edited line goes into the text view buffer → binding → `NotesModel.textChanged()` (`NotesView.swift:1190,1459`) → 800 ms autosave → file → reindex.
- **Master-list path:** `VaultIndexService.toggle` (`VaultIndexService.swift:1247-1278`): recurring → `TaskLineToggler.locate` + `RecurrenceEngine.completeTaskLine`; non-recurring → `TaskLineToggler.toggle(completionDay: TodoView.todayISO())` (`Packages/MarkdownKit/Sources/MarkdownKit/TaskLineToggler.swift:16-45`), which stamps/strips. Two implementations of "flip", two packages.
- **Reading mode** (`NotesView.swift:1390-1403`) routes to `indexService.toggle` after a raw-line drift check — already stamps; plan's "(and iOS)" wording is right for the editor, not for Reading mode.
- `TaskLineToggler` lives in **MarkdownKit**, not TaskEngine (plan says "TaskLineToggler parity" without a package; note the location). TaskEngine has no dependencies; MarkdownKit does not import TaskEngine; EditorKit, ReadingKit, IndexKit import both. So the single primitive must live in **TaskEngine** (EditorKit already calls it — that is the existing seam; no new injection is needed).
- `TaskLineToggler.toggle` production callers: only `VaultIndexService.swift:1263`. Test users: `MarkdownKitTests/TaskLineTogglerTests.swift` (5 cases), `SyntaxMarkerTests.swift:252-266` (`CompletionTokenToggleTests`), `ReadingKitTests/ReadingDocumentTests.swift:352-361`.
- `IndexKit` `PipelineIntegrationTests.editorAndMasterListCompletionAgree` (`:89-102`) only checks the recurring case; `RecurrenceTests.nonRecurringLineJustFlips` (`:95-98`) pins the current no-stamp behaviour and must change.
- Autosave/flush seam: `indexService.beforeNoteMutation` flushes the editor before any service write (`AppShell.swift:113-116`); `onNoteMutated` reloads the displayed note (`:110-112`).

## Design

**Primitive (TaskEngine, `Recurrence.swift`):** keep the signature `RecurrenceEngine.completeTaskLine(_ line: String, today: Date = Date(), calendar: Calendar = .current) -> String?` and change the non-recurring branch:

- `[ ]` → `[x]`, then append ` ✅<today as yyyy-MM-dd in calendar.timeZone>` before any trailing spaces/`\r` (same byte rule as the old toggler), after first removing any existing ✅ token.
- `[x]`/`[X]` → `[ ]`, and remove ` ?✅\d{4}-\d{2}-\d{2}` (one adjacent space).
- Recurring: unchanged (advance date, box stays open); additionally strip a stale ✅ token if present (a `[ ]` line with ✅ is contradictory).
- Add `public static func isoDay(_ date: Date, calendar: Calendar) -> String` (reuse the existing private formatter) so the App stops formatting dates itself in this path.
- `completeTask(in:tokenRange:)` needs no change; it inherits the behaviour.

**Service (`VaultIndexService.toggle`):** one branch for all tasks: `TaskLineToggler.locate` → `RecurrenceEngine.completeTaskLine(task.rawLine)` → `TaskLineToggler.replacingLine` → coordinated write → reindex. Drift protection stays (locate refuses when the raw line changed). `TodoView.todayISO()` is no longer used here (keep it for the Logbook grouping).

**MarkdownKit:** delete `TaskLineToggler.toggle` and `TaskLineToggler.Result`; keep `locate`, `replacingLine`, `removingLine`. Migrate its tests (table below). This removes the second implementation instead of leaving it for tests only.

**Editor:** no code change. The editor edits the clicked line in the buffer (undo stack intact, `textDidChange` fires); the file catches up through the existing autosave, and the index through the existing reindex. Decision recorded: routing editor clicks through `VaultIndexService` (flush → file rewrite → reload) was considered and rejected for Phase 1 — it would lose the cursor/undo and add a flush on every click; one line primitive already guarantees identical bytes.

## Acceptance criteria

1. `completeTaskLine("- [ ] once")` on day D returns `"- [x] once ✅D"`; on that result returns `"- [ ] once"`.
2. For any line L, `completeTask(in: L + "\n", tokenRange: firstBox)` equals `completeTaskLine(L) + "\n"` (recurring and non-recurring).
3. Checking a box in the Mac editor, saving, and opening the Logbook shows the task under today; unchecking there reopens it with no ✅ in the file.
4. Same on iPhone (editor tap) and in Reading mode on both.
5. No `TaskLineToggler.toggle` symbol remains; `swiftformat --lint .` clean; `linux-packages` CI job green (TaskEngine, MarkdownKit, IndexKit are Linux-built).

## Files expected to change

`Packages/TaskEngine/Sources/TaskEngine/Recurrence.swift`, `Packages/TaskEngine/Tests/TaskEngineTests/{RecurrenceTests.swift, TaskCompletionTests.swift (new)}`, `Packages/MarkdownKit/Sources/MarkdownKit/TaskLineToggler.swift`, `Packages/MarkdownKit/Tests/MarkdownKitTests/{TaskLineTogglerTests.swift, SyntaxMarkerTests.swift}`, `Packages/ReadingKit/Tests/ReadingKitTests/ReadingDocumentTests.swift`, `Packages/IndexKit/Tests/IndexKitTests/PipelineIntegrationTests.swift`, `App/Services/VaultIndexService.swift` (only `toggle`).
Must NOT touch: `EditorKit` sources, `NotesView.swift`, `TodoView.swift`, `TaskTokenParser.swift`, `TaskLineRewriter.swift` (spec 03/06 own it).

## Test plan

TaskEngine `TaskCompletionTests` (fixture `today` = a fixed date, `calendar` = Gregorian/UTC like `RecurrenceTests`):

| case | input | expected |
|---|---|---|
| `checkStampsToday` | `- [ ] once` | `- [x] once ✅D` |
| `checkReplacesStaleStamp` | `- [ ] once ✅2020-01-01` | `- [x] once ✅D` |
| `uncheckStripsStamp` | `- [x] once ✅2026-07-10` | `- [ ] once` |
| `uncheckWithoutStampJustFlips` | `- [X] once` | `- [ ] once` |
| `stampKeepsTrailingWhitespaceAndCR` | `- [ ] once  \r` | `- [x] once ✅D  \r` |
| `stampGoesAfterOtherTokens` | `- [ ] x >2026-07-20 !p1 #t @a ?discuss` | same + ` ✅D` |
| `nestedAndNumberedPrefixes` | `  - [ ] sub`, `1. [ ] n` | flipped + stamped |
| `recurringStaysOpenNoStamp` | existing `completingRecurringLineAdvancesDateStaysOpen` | unchanged |
| `recurringStripsStaleStamp` | `- [ ] w >2026-07-10 &every 3 days ✅2026-07-01` | `- [ ] w >2026-07-13 &every 3 days` |
| `noCheckboxReturnsNil` | `- plain` | nil |
| `isoDayUsesCalendarTimeZone` | date near midnight, two zones | differs by one day |

Update `RecurrenceTests.nonRecurringLineJustFlips` to the stamped expectations; add `completeTaskStampsSecondLineInDocument` next to `completeTaskSplicesWholeDocument`.
MarkdownKit: `TaskLineTogglerTests` becomes `locate`/`replacingLine` tests (`locatesAtAnchor`, `relocatesMovedLine`, `refusesWhenLineContentChanged`, `replacingLinePreservesEverythingElseByteForByte`); delete `CompletionTokenToggleTests` (covered above).
ReadingKit `ReadingDocumentTests:352-361`: use `locate` + `completeTaskLine` + `replacingLine`; same assertions.
IndexKit `PipelineIntegrationTests`: extend `editorAndMasterListCompletionAgree` with a non-recurring line; add `editorCompletionAppearsInLogbook` (index note → `completeTask` on its text → index again → `completedTasks()` contains the task with `completedDay == D`; then uncheck → gone).

## Non-goals

Changing where the editor writes (buffer vs file), time-of-day in the stamp, widget check-off (no such surface exists yet), the Logbook UI.

## Risks / invariants

- **FEATURES §2.7/2.8:** the master list stays a live view; this pass removes the second engine rather than adding a third.
- **Single source of truth / drift guard:** the service path keeps `locate` + `expectedRawLine`; the editor path edits only the clicked paragraph. Do not add a blind `firstIndex(of:)` write anywhere.
- **Autosave ordering:** nothing here changes `beforeNoteMutation`/`flushSave`; do not call `indexService.toggle` from the editor.
- Linux: `DateFormatter` with `en_US_POSIX` is already used in this file; keep it, no `FormatStyle`.

## Builder model

sonnet. The invariant judgement (buffer vs file routing) is decided above; the rest is mechanical with a full test table.

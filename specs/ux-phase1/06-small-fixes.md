# 06 — Small fixes: Face ID key, iPhone-safe sheets, batch/person-page gaps, `!med` parity, search empty state

Six independent items. Each is one commit (`FIX:` prefix) unless the builder groups the sheet gating with its surface.

## 6a. `NSFaceIDUsageDescription`

**Verified:** `project.yml` generates `App/Info.plist` from `targets.Notetaker.info.properties` (it already holds `NSLocalNetworkUsageDescription`, `NSCalendarsFullAccessUsageDescription`). `grep -rn NSFaceIDUsageDescription .` finds nothing. `SecurityKit.swift:33-45` evaluates `.deviceOwnerAuthentication` via `LAContext`; on iOS, Face ID needs the key or evaluation fails.
**Design:** add `NSFaceIDUsageDescription: Notetaker uses Face ID to unlock the app and your locked notes.` to `info.properties`; run `xcodegen generate`; confirm the key in the generated `App/Info.plist`. Never edit the pbxproj or the plist by hand.
**Acceptance:** app lock on an iPhone with Face ID prompts with Face ID (not passcode-only). Manual.
**Files:** `project.yml` (+ regenerated `App/Info.plist`, `Notetaker.xcodeproj`).

## 6b. Fixed-width sheets overflow the iPhone

**Verified** fixed frames on sheet content: `NotesView.swift:1672` (`width: 460, height: 480`, proofread), `:2174` (`width: 420`, lock), `:2195` (`width: 380`, unlock); `TaskDetailView.swift:55` (`minWidth: 460…`, presented as a sheet from TodoView/MeetingsView/ProjectsView/NotetakerApp); `MeetingsView.swift:438` (`minWidth: 460, minHeight: 420`, MeetingRunView); `CommandPalette.swift:82` (`width: 560`; reachable on iOS only with a hardware keyboard); `GraphView.swift:97` (`minWidth: 600, minHeight: 460`). **Not in the plan:** `TodoView.swift:532` (`minWidth: 420` on the Quick Add sheet). `SettingsView.swift:128` is inside `#if os(macOS)` — fine. No `horizontalSizeClass` use exists anywhere in `App/`.
**Design:** one modifier in `App/Shell/SheetFrame.swift`:
```swift
extension View {
    /// macOS: the fixed sheet size. iOS: fill the sheet; a phone never gets a fixed width.
    func sheetFrame(width: CGFloat? = nil, height: CGFloat? = nil,
                    minWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
                    idealWidth: CGFloat? = nil, idealHeight: CGFloat? = nil) -> some View
}
```
`#if os(macOS)` applies the same `.frame(...)` as today (byte-for-byte same arguments per site); `#else` applies `.frame(maxWidth: .infinity, maxHeight: .infinity)`. Replace the eight sites. Keep `presentationDetents` where present (`TodoView:533`).
**Acceptance:** every sheet above opens within the iPhone screen with no horizontal clipping; the Mac sizes are unchanged (compare before/after screenshots of the proofread and task-detail sheets).
**Files:** the eight files above + new `SheetFrame.swift`. Package: none.

## 6c. Batch actions skip Next/Someday tasks

**Verified:** `TodoView.refresh()` (`:595-597`) splits `nextTasks`, `somedayTasks` out of `grouped`; `allFilteredTasks` (`:199-201`) is `grouped` only; `batch()` (`:452-453`) and Select All (`:412-415`) filter by it, while the List at `:340-379` lets those rows be selected. So a selected `?next` task is silently dropped from Complete/Priority/… and "Select All" never includes them. Claim correct.
**Design:** `private var batchableTasks: [TaskRecord] { allFilteredTasks + nextTasks + somedayTasks }`; use it in Select All, its `disabled` check, and `batch()`. Leave `allFilteredTasks` for the Agenda/Matrix views (`:326,331`) so those views do not change.
**Acceptance:** select a `?someday` row and a Today row, press Complete → both lines are completed in their files; Select All counts include Next/Someday.
**Files:** `App/Todo/TodoView.swift`.

## 6d. `@person ?next` / `?someday` tasks are counted but shown nowhere on the person page

**Verified:** `IndexDatabase.peopleTasks` (`IndexKit/IndexDatabase.swift:444-455`) returns every open task with an assignee **or** kind in `discuss/waiting/followup`; `MeetingsView.people` counts them all (`:28-36`, `total`); `personPage` (`:150-154`) renders only kind `discuss`, `nil`, `waiting`, `followup`. An `@Amber ?next` task raises Amber's count and appears in no section. Claim correct. No IndexKit change needed.
**Design:** add `let later = tasks.filter { assignee == person && ($0.kind == "next" || $0.kind == "someday") }` and a fifth section "Later (N)" (icon `tray`, collapsed `DisclosureGroup` by default) after Follow-ups, reusing the existing row builder. Update the detail placeholder text (`:112-115`) to mention it only if it lists sections.
**Acceptance:** `- [ ] plan offsite @Amber ?someday` shows under Amber › Later; count in the people list equals the sum of the five sections.
**Files:** `App/Todo/MeetingsView.swift`.

## 6e. `!med` parity: parser accepts it, rewriter does not

**Verified:** `TaskTokenParser.priorityRegex` (`TaskTokenParser.swift:272-287`) accepts `p1-4|high|medium|med|low`; `TaskLineRewriter.settingPriority` (`TaskLineRewriter.swift:99-117`) matches `p[1-4]|high|medium|low` — no `med`. Setting a priority on `- [ ] x !med` appends a second token (`!med !p1`), and the parser then reads the first. Claim correct.
**Design:** expose the vocabulary once: `public static let priorityTokenPattern` on `TaskTokenParser` (the string used by `priorityRegex`), and make `settingPriority` build its regex from it. Same treatment for `settingKind` and `kindRegex` (`:134-135` vs `:121`), which are identical today but duplicated — the CLAUDE.md "change in one pass" rule gets a single site.
**Tests (`TaskEngineTests`, new `TaskLineRewriterParityTests`):** `settingPriorityReplacesEveryAliasParserAccepts` (loop over `p1 p2 p3 p4 high medium med low`: result has exactly one `!` token and `TaskTokenParser.parse` reports the new value); `removingPriorityStripsMedAlias`; `settingKindReplacesEveryVocabularyWord`; `rewriterPatternsAreParserPatterns` (string equality).
**Files:** `Packages/TaskEngine/Sources/TaskEngine/{TaskTokenParser.swift, TaskLineRewriter.swift}`, tests. Coordinate with spec 03 (same files; same builder, sequential).

## 6f. Zero search results show "No Notes Yet / Press ⌘N"

**Verified:** `NotesView.swift:619-626` overlays `ContentUnavailableView("No Notes Yet", … "Press ⌘N or tap New Note…")` whenever `visibleNotes.isEmpty`; `visibleNotes` (`:2105-2119`) is the search/tag-filtered list, so a search with no hits shows the onboarding text, and iPhone users read "Press ⌘N". Claim correct.
**Design:**
```swift
if visibleNotes.isEmpty {
    if searching || selectedTag != nil { ContentUnavailableView.search(text: searchText) }   // "No Results for …"
    else if model.notes.isEmpty { ContentUnavailableView("No Notes Yet", systemImage: "note.text", description: Text(newNoteHint)) }
}
```
`newNoteHint`: `#if os(macOS)` "Press ⌘N or choose New Note to create your first markdown note." `#else` "Tap New Note to create your first markdown note." For the tag-filter case use "No notes tagged #tag".
**Acceptance:** searching "zzzz" shows "No Results"; an empty vault shows the platform-specific hint; a folder with notes but no hits never shows the onboarding text.
**Files:** `App/Notes/NotesView.swift`.

## Shared

**Non-goals:** Dynamic Type/accessibility pass (Phase 5), redesigning any sheet, new keyboard shortcuts.
**Risks:** 6b touches seven view files — keep each change to the one `.frame` line; the macOS branch must keep identical arguments or the sheets resize (regression guard: "stable table heights"). 6e changes a regex source string only; the parser's behaviour must not change (`TaskTokenParserTests` stays green).
**Builder model:** sonnet for all six.

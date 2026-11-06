# UX Phase 2 — Mac structure (overview)

Plan: `~/.claude/plans/idempotent-conjuring-bear.md` (roadmap line "Phase 2"). Specs written 2026-11-06 from the code at `2f47fe0` (Phase 1), not from running the app. Each spec's "Verified findings" says what was confirmed and where the plan and the code disagree. Phase 1's format is the model (`specs/ux-phase1/`).

## Scope

| spec | what | plan status after verification |
|---|---|---|
| 01 | Menu bar `.commands` (File/Edit/Format/View/Note/Go), ⌘1-6, ⌘W, one `ShellCommand` table + `ShellCommandBus`; every hidden-button shortcut re-homed | finding #8 correct; 18 hidden/mounted-only shortcuts inventoried (one lives in a `.toolbar` on the To-Do tab, which contradicts the trap list but works there) |
| 02 | Command palette v2: ranked titles, ↑/↓/↩/⎋, FTS body hits, recents, commands mirrored from spec 01 | finding #11 correct |
| 03 | UI state that survives tab switches; last tab + last note restored at launch (Mac only); trashed/missing notes never restored | finding #9 half right: selection/tabs/text already survive (they live in `NotesModel`); only `NotesView`'s `@State` resets |
| 04 | Editor header option (c): title row + tool row, ⋯ overflow, text mode picker, one surface tone, 780 pt text column (macOS only) | plan's mockup is **not** in the plan file (it was in the questions to Robert); designed from the option text |
| 05 | One wikilink parser/rewriter/resolver in MarkdownKit; Rename note with inbound `[[link]]` rewrite, preview, Undo | regex disagreement confirmed and worse than stated: Reading mode shows and tries to open `Note|alias` as a title. Found an unrelated data bug on the way (locked-note re-keying on move, fixed in 05) |
| 06 | ⌘-click opens wikilinks in Source and Live; shared resolver; offer to create a missing note; heading/block anchors | correct: the editor never puts a `.link` attribute on wikilinks (`MarkdownHighlighter.swift:277` does it for checkboxes only) |

## Build groups (file sets) and order

| group | specs | files | model |
|---|---|---|---|
| **A — menu gate** | 01 | `App/NotetakerApp.swift`, `App/Shell/ShellCommands.swift` (new), `App/Shell/AppShell.swift`, `App/Notes/NotesView.swift` (shortcut removal + request handling only), `App/Shell/SettingsView.swift` (one caption), `App/Todo/TodoView.swift` (one line, see note) | sonnet |
| **B — packages** | package halves of 02, 04, 05, 06 | `Packages/MarkdownKit/Sources/MarkdownKit/{Wikilinks.swift (new), NoteScanner.swift, StyleRanges.swift}` + tests; `Packages/ReadingKit/Sources/ReadingKit/{ReadingBlock, ReadingDocument, ReadingInlineText, ReadingView}.swift` + tests; `Packages/IndexKit/Sources/IndexKit/PaletteRanking.swift` (new) + tests; `Packages/EditorKit/Sources/EditorKit/{EditorMode, MarkdownEditor, MarkdownRichTextView, WikilinkHitTest.swift (new)}` + tests; `Packages/VaultKit/Tests/VaultKitTests/VaultFileStoreTests.swift` (one test) | sonnet |
| **C1 — palette + state** | 02 (app half), 03 | `App/Shell/CommandPalette.swift`, `App/Shell/AppShell.swift`, `App/Notes/NotesModel.swift`, `App/Notes/NotesView.swift` | sonnet |
| **C2 — editor header** | 04 (app half) | `App/Notes/NotesView.swift` | sonnet |
| **C3 — rename + links** | 05 (app half), 06 (app half) | `App/Notes/{NotesModel, NotesView, RenameNoteSheet.swift (new)}`, `App/Services/VaultIndexService.swift`, `App/Shell/ShellCommands.swift` (add `renameNote`) | **opus** — it edits many files under coordination, interleaves with autosave/title-sync, and re-keys locked-note keys (spec 05 "Why opus") |

Order: **A first and gated.** A's step 1 (the `.commands` launch proof, spec 01 §"Step 1") must pass its launch check before A continues; its fallback (AppKit-built menu over the same bus) keeps the rest of A and all of C unchanged, so nothing downstream waits on *how* the menu is built, only on the `ShellCommand`/`ShellCommandBus` types existing. **B can run in parallel with A** (disjoint files; in a worktree, because `xcodegen`, DerivedData and `verify.sh` are shared in one checkout). **C1 → C2 → C3 strictly sequential** (all touch `NotesView.swift`; C3 needs C2's title row and B's packages; C1 needs A's command table). Within B, do MarkdownKit (05) before ReadingKit and EditorKit (both consume `Wikilink`).

Note on `App/Todo/TodoView.swift`: it is in the uncommitted "nits" set at spec time. Group A's only change there is deleting the `.keyboardShortcut("n", modifiers: [.command, .shift])` line at `TodoView.swift:127`. If the nits are still uncommitted when A runs, leave that line alone and record it in PROGRESS (a duplicate ⇧⌘N is harmless: both routes open Quick Add).

Dependencies: 02's palette command list = 01's `ShellCommand.allCases`. 03 writes `ui.*` keys that 01's ⌘W/⌘1-6 handlers must respect (they only mutate `selectedTab`, which 03 persists). 05's `Wikilink` type is consumed by 06 and by ReadingKit. 06's `createNote(titled:in:)` lives in `NotesModel` next to 05's `rename`.

## Shared verify steps (every pass)

- Toolchain: `DEVELOPER_DIR=/Applications/Xcode.app` on every build. Build products under `~/.cache/notetaker-build/...`, never in the repo.
- `Notetaker.xcodeproj` is generated; `project.yml` picks up every file under `App/` and `Shared/` by directory, so **new Swift files need no `project.yml` edit**, only `xcodegen generate` (which `scripts/verify.sh` runs first). Nothing in Phase 2 edits `project.yml`.
- Package tests: `cd Packages/<Kit> && DEVELOPER_DIR=/Applications/Xcode.app swift test --scratch-path ~/.cache/notetaker-build/<Kit>`. Group B runs MarkdownKit, ReadingKit, IndexKit, EditorKit, VaultKit tests after each spec; IndexKit's `PipelineIntegrationTests` is where cross-module behaviour (index → backlinks → rewrite candidates) is asserted.
- Gate before each commit: `scripts/verify.sh 3 --install` (all packages ×3, macOS build, iOS Simulator Debug + Release builds, install + 8 s launch check) and `swiftformat --lint .`.
- Phone: `scripts/install-ios.sh --yes` (Release) after C1 and C3; the iPhone checklist below is the regression guard for the shared files.
- Linux: MarkdownKit, IndexKit touch the `linux-packages` CI job; `Wikilinks.swift` and `PaletteRanking.swift` must use Foundation only (`NSRegularExpression`, `NSString`), no AppKit/UIKit.

## Commit and PROGRESS.md convention

One group = one commit, only when Robert asks. Each commit carries the code **and** one new row in the `| # | Date | Step | Result | Notes |` table of `PROGRESS.md` (next number after the last row, today's date, ✅, Notes = what changed, tests added, verify result, anything skipped or deferred, the launch-proof outcome for A). Message prefixes: `Shell:` (A, C1), `Editor:` (C2), `Notes:` (C3), `MarkdownKit:`/`EditorKit:` (B). Do not edit PLAN.md (shakedown work). End messages with the attribution line the session gives.

## Decisions taken in the specs (Robert can override)

1. **⌘W closes the open note tab** in the vault window and closes secondary windows (Task detail, Settings) when they are key; it never closes the vault window. ⇧⌘W is "Close Window". (01)
2. Format shortcuts (⌘B, ⇧⌘I, ⌥⌘C, ⇧⌘T, ⇧⌘K) move to a **Format** menu and are removed from the format-bar buttons; the buttons stay. (01)
3. Rename Note gets **⌥⌘R** (⌘R stays Refresh). (01, 05)
4. Palette ranking: exact > prefix > word-prefix > substring > in-order subsequence, recents get a bonus, body hits (FTS5) appear in their own section only for queries of 3+ characters. No typo tolerance. (02)
5. Restore at launch is **macOS only**: last tab and last note. iPhone launches on Notes with nothing selected, as today. Sidebar search text and tag filter now survive a tab switch on **both** platforms (they move into `NotesModel`). (03)
6. Mode picker uses text labels in the existing enum order **Source · Live · Reading** (matches the ⌘E cycle), not "Live / Source / Reading". (04)
7. Title row shows the file name (not the H1); double-click opens Rename. The locked-note placeholder keeps its current chrome-less look. The stats chip keeps its glass capsule (it floats over the text, not in the chrome). (04)
8. Renaming always sets the note's first heading to the new title when the first body line is a heading, so title-sync cannot rename the file back. (05)
9. Rename refuses a name that exists (no auto-uniquify) and refuses to rename a note with unresolved sync conflicts. Inbound notes that are locked or conflicted are skipped and listed; the rest proceed. **Undo Rename** is a reverse rename through the same code, offered for 6 s. (05)
10. `[[Folder/Note]]` resolves by path first, then by title; NoteScanner indexes the last path component as the target title. (05)
11. Wikilinks open on **⌘-click** in both Source and Live (plain click places the caret). An unresolved target offers to create the note in the source note's folder. (06)
12. Reading mode now displays the alias of `[[Note|alias]]` (it displayed `Note|alias`). Live mode still only hides the brackets. (05)

## Manual checklist for Robert

**Mac**
- [ ] Launch: traffic lights present, no black strip on any tab, menu bar shows File · Edit · Format · View · Note · Go with the new items. ⌘1…⌘6 switch tabs from any tab; ⌘7 shows Vault in a Debug run only.
- [ ] From the To-Do tab: ⌘N creates a note and lands on Notes; ⇧⌘D opens today's daily note; ⇧⌘N opens Quick Add; ⌘K opens the palette; ⌘R refreshes (also while the spinner is showing).
- [ ] In the editor: ⌘B/⇧⌘I/⌥⌘C/⇧⌘T/⇧⌘K format as before; ⌘E cycles modes; ⌘/ flips Source↔Live; ⌘= ⌘- ⌘0 zoom the active mode; ⌥⌘0 toggles the inspector; ⇧⌘P proofreads; ⌘F opens the find bar. Format items are greyed out in Reading mode and on the other tabs.
- [ ] ⌘W: closes the current note tab (strip shrinks; next tab selected). With one note open it deselects it. In a Task window or Settings, ⌘W closes that window. The vault window never closes on ⌘W; ⇧⌘W closes it.
- [ ] Palette: type a title fragment → best match first; ↓↓↩ opens the third; ⎋ closes; empty query shows recent notes then commands; a word that only appears in a note body lists it under "In note text"; `add call Amber >friday` still adds the task.
- [ ] Quit with the Projects tab and note X open → relaunch: Projects tab shown; switch to Notes: X is open. Trash X, quit, relaunch: nothing selected, no error. Expanded folders, inspector state and the sidebar search text survive a tab switch; expanded folders and inspector survive a relaunch.
- [ ] Editor header: title row (name, daily ◀ ▶ when a daily note, ⋯), tool row (format cluster left, Source · Live · Reading right); the whole header is one opaque tone; text column ≤ 780 pt and centred on a wide window; Reading mode is the same width. Every former button is reachable (format bar, picker, ⋯ menu). Tab strip still appears above with 2+ notes.
- [ ] Rename "Plan" → "Plan 2026" with three notes linking `[[Plan]]`, `[[Plan|the plan]]`, `[[Plan#Budget]]`: sheet says 3 links in 3 notes; after Rename the file is `Plan 2026.md`, its H1 is `# Plan 2026`, all three links keep alias/heading, the Backlinks inspector of the renamed note lists the three. Undo in the toast reverses everything. Renaming to an existing name is refused. Case-only rename (`plan`) works. A locked note that links here is listed as skipped and its bytes are unchanged.
- [ ] Daily folder lists newest first (today on top), with Settings › Sort notes by = Name AND Modified; a year/month subfolder inside Daily, if you have one, is newest first too. Other folders are unchanged.
- [ ] Rename an **unlocked locked note**, then type: the file on disk is still ciphertext (`locked: true` + base64), never plaintext. Same for Move To ▸ folder.
- [ ] ⌘-click `[[Plan 2026]]` in Source and in Live opens it; ⌘-click `[[Plan 2026#Budget]]` lands on that heading; ⌘-click `[[Nonexistent]]` offers "Create "Nonexistent"?" and creates it next to the current note; plain click and click-drag still place the caret and select. Reading mode: `[[Note|alias]]` shows "alias" and opens Note.
- [ ] Checkbox click in the editor still toggles and stamps ✅; heading margin click still folds; image click still opens; Trash/Undo, conflict sheet, lock/unlock, proofread, graph all open from their new homes.

**iPhone (Release via `install-ios.sh --yes`)**
- [ ] Six tabs, Notes opens with nothing selected (no restore). Editor chrome identical to Phase 1 (icon mode picker, action bar). Tap a wikilink in Reading mode: opens the note. Long-press a note ▸ Rename… works and fits the screen. Trash/Undo, To-Do and Tags navigation unchanged.

# UX Phase 1 — safety and broken-on-device fixes (overview)

Plan: `~/.claude/plans/idempotent-conjuring-bear.md` (Phase 1 bullet). Specs written 2026-11-05 from code, not from running the app; each spec's "Verified findings" says what was confirmed and where the plan was wrong.

## Scope

| spec | what | plan status after verification |
|---|---|---|
| 01 | Trash (`<vault>/.trash/`) + confirm + Undo toast + Trash sheet; tag-action confirmations | correct; observer has no hidden filter (fixed in spec) |
| 02 | One completion primitive in TaskEngine; editor/Reading/list all stamp `✅` | correct for the editor; Reading mode already stamps; `TaskLineToggler` is in MarkdownKit, not TaskEngine |
| 03 | Quick Add keeps `@ ? ~ ^ blockedby:`; AI path cannot drop tokens | correct; AI gate also leaky (fixed) |
| 04 | iPhone To-Do/Tags navigation; no Vault tab on iOS; Release installs | consistent with PROGRESS 228 mechanism; must be confirmed on the phone |
| 05 | Conflict sheet from the badge; Keep mine/other/both | **plan wrong:** NSFileVersion logic already lives in VaultKit (`VaultConflictCenter`); work is two strategies + a fake-able source |
| 06 | Face ID key, iPhone-safe sheets (+ `TodoView:532`, missed by the plan), batch Next/Someday, person-page Later section, `!med` parity, search empty state | all correct |

## Build groups (disjoint file sets) and order

| group | specs | files | builder |
|---|---|---|---|
| **A — engine** | 02 → 03 → 06e | `Packages/TaskEngine/**`, `Packages/MarkdownKit/{TaskLineToggler.swift, tests}`, `Packages/ReadingKit/Tests`, `Packages/IndexKit/Tests`, `App/Services/VaultIndexService.swift` | sonnet |
| **B — vault + notes** | 01 (notes part) → 05 → 06b (NotesView sites) → 06f | `Packages/VaultKit/**`, `Packages/MarkdownKit/Tests/ExportPolicyTests.swift`, `App/Notes/{NotesModel, NotesView, TrashSheet, ConflictSheet}.swift`, `App/Debug/VaultDebugModel.swift`, `App/Shell/SheetFrame.swift` (new; create here first) | sonnet |
| **C — shell + todo** | 04 → 01 (TagsView confirmations) → 06a → 06c → 06d → 06b (remaining sites) | `App/Todo/{TodoView, MeetingsView, TaskDetailView}.swift`, `App/Notes/TagsView.swift`, `App/Shell/{AppShell, CommandPalette, SettingsView}.swift`, `App/Notes/GraphView.swift`, `project.yml`, `scripts/install-ios.sh`, `scripts/verify.sh`, `CLAUDE.md` | sonnet |

Rules: groups A, B, C edit disjoint files, so they can run concurrently **in worktrees**; in one checkout they must run sequentially because `xcodegen generate`, DerivedData and `verify.sh` are shared. Recommended serial order **A → B → C** (A changes a primitive the others merely call; C ends with the Release switch so the final phone install is the Release build). Inside a group the order above is required (shared files). 06b's `SheetFrame.swift` is created by B and consumed by C; if C runs first it creates it and B adopts it.

Dependencies: 05 depends on 06b's helper (or inlines the `#if os` frame until it exists). 04's Release switch should land after everything else is built so the final `install-ios.sh --yes` exercises Release. Nothing depends on 02/03 except their own tests.

## Shared verify steps (every pass)

- Toolchain: prefix every build with `DEVELOPER_DIR=/Applications/Xcode.app`. Build products outside the repo (`~/.cache/notetaker-build/...`); never `build/` or `.build/` in the repo. `project.yml` is the source; after editing it run `xcodegen generate`; never touch the pbxproj.
- Package tests: `cd Packages/<Kit> && DEVELOPER_DIR=/Applications/Xcode.app swift test --scratch-path ~/.cache/notetaker-build/<Kit>`.
- Gate before each commit: `scripts/verify.sh 3 --install` (all packages ×3, both builds, launch check) and `swiftformat --lint .`.
- Phone: `scripts/install-ios.sh --yes` with the phone unlocked, trusted, Developer Mode on; it checks the installed build number. After spec 04 this is a Release build (`--debug` for the old behaviour); first prove Release compiles with the simulator build in spec 04.
- Linux: TaskEngine, MarkdownKit, IndexKit, MCPKit, RemoteServer are built by the GitHub Actions `linux-packages` job; check it after group A.

## Commit and PROGRESS.md convention

One pass = one commit containing the code **and** one new row appended to the `| # | Date | Step | Result | Notes |` table in `PROGRESS.md` (next number after the last row; today's date; Result ✅; Notes: what changed, test names added, verify result, anything skipped). Message prefixes: `FIX:` for bug fixes (02, 03, 06c-f), `iOS:` for phone-only work (04), `Notes:`/`VaultKit:` style descriptive prefixes for 01 and 05 (`Notes: Trash + undo-delete`, `VaultKit: conflict resolution sheet`). Commit only when Robert asks; end messages with the attribution line the session gives. Do not edit PLAN.md (these are shakedown items, not plan steps).

## Decisions taken in the specs (Robert can override)

1. Trash folder is `.trash` (hidden, Obsidian's name), not a visible `Trash/` folder. Confirmation dialog **and** Undo toast both on (drop the dialog if that feels heavy).
2. Completion stays a line primitive (editor edits its buffer; the service edits the file); `TaskLineToggler.toggle` is deleted rather than kept as a second implementation.
3. Any grammar token bypasses the AI Quick Add parser.
4. iPhone installs switch to Release by default; a Release iOS-simulator build is added to `verify.sh`.
5. Person page gets a collapsed "Later" section for `?next`/`?someday`.

## Manual checklist for Robert

**Mac**
- [ ] Right-click a note › Move to Trash › confirm: note leaves the list, search, To-Do, Tags; Finder shows it under `.trash/` (⌘⇧.); Undo in the toast brings it back selected.
- [ ] Trash sheet: Restore puts a note back in its folder; Delete Permanently and Empty Trash ask first.
- [ ] Trash a note with unsaved typing: the trashed file contains the last keystrokes.
- [ ] Tags: Remove Tag Everywhere and Delete All ask first; Cancel changes nothing. Rename… (context menu) still opens its text-field alert next to the new confirmation dialog.
- [ ] Click a checkbox in the editor; the file line reads `[x] … ✅today`; Logbook lists it; uncheck in Logbook removes the ✅ from the file. Same from Reading mode and the To-Do list. A `&every` task advances its date and stays `[ ]`.
- [ ] Quick Add (⇧⌘N) "call Amber @Amber ?waiting ~2026-12-01 ^amber-call": `Inbox.md` line carries every token; the same via the menu-bar capture and Shortcuts "Add Task".
- [ ] Orange conflict badge: click opens the sheet; Keep mine / Keep other / Keep both each converge (make a real conflict with the phone in Airplane Mode).
- [ ] Task detail, proofread, lock/unlock, meeting run, graph and palette sheets look exactly as before.
- [ ] Select a Today task and a Someday task → Complete: both done. Meetings › a person with an `@person ?someday` task shows "Later".
- [ ] `- [ ] x !med` › set priority P1 in Task Detail → one `!p1` token, no `!med` left.
- [ ] Search "zzzz" → "No Results"; empty vault → "Press ⌘N" hint.
- [ ] Debug build (`scripts/install-ios.sh --debug --yes`, or a Mac Debug run): the Vault tab is back, and its Keep Both button still resolves a conflict (it now runs through `VaultConflictCenter.resolve(.keepBoth)`).

**iPhone (Release build via `install-ios.sh --yes`)**
- [ ] Six tabs; Settings has no Debug entry.
- [ ] To-Do: tap Today → task list opens; Back; tap Upcoming → opens again; saved filter rows work.
- [ ] To-Do: tap a saved filter (list is filtered), Back, tap a view such as Upcoming → no filter is left applied. A filter you typed yourself survives Back.
- [ ] Tags: tap a tag → detail opens; long-press › Rename works.
- [ ] Notes: long-press › Move to Trash asks; Undo works; trashed note is absent from the list after sync; Trash sheet restores.
- [ ] Tap a checkbox in the editor → `✅today` in the file (check on the Mac); Reading mode same.
- [ ] App lock prompts with Face ID.
- [ ] Open a task detail, Quick Add, and the lock sheet: nothing is clipped at the right edge.
- [ ] Conflict badge reachable (tap or long-press › Resolve Conflict…) and resolves.

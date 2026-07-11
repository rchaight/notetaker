# Notetaker — build-loop progress log

Loop-engineering state file. Read this + PLAN.md at the start of every pass.

## Loop contract

- **Trigger** — self-paced: passes chain immediately (~60s) inside a milestone; the loop BREAKS at every milestone boundary and waits for user review before entering the next milestone.
- **Termination** — all PLAN.md steps checked AND verify green (build + tests + functional exercise of every component) AND user accepts the final composed version. Breaker: 3 consecutive failed passes → notify + halt.
- **State** — PLAN.md checkboxes = cursor · this file = log/streak · git commits = accumulator. One commit per pass containing the code change AND its checked box (atomic progress).
- **Work per pass** — exactly one PLAN.md step: implement → verify → commit.
- **On failure** — append a log row, streak +1, back off (60s → 270s → 1200s). Only success checks a box and resets the streak. At streak 3: push notification, halt, await user input.

## Current state

- **Phase**: M2 complete — milestone checkpoint
- **Current milestone**: M2 done (next: M3 — inline todos + master To-Do list)
- **Failure streak**: 0
- **Awaiting user checkpoint**: **YES — exercise the editor on Mac + iPhone (see checkpoint criteria), then continue the loop**
- **Branch protection**: proceeding unprotected (private repo, GitHub Free; no user objection at checkpoint — revisit anytime)
- **Environment note**: toolchain = **Xcode 27.0 beta** (`DEVELOPER_DIR=/Applications/Xcode-beta.app`, macOS/iOS 27 SDKs, iOS 27 sim runtime installed) per user directive. Deployment floor 26.0 until a 27-only API is needed. Developer ID cert present (team 6A2NHN89Q8). ⚠️ Repo is inside iCloud-synced ~/Documents — ALL build products must use external paths (see CLAUDE.md).

## Milestone checkpoints

| Milestone | Completed | User reviewed |
|---|---|---|
| M0 — Repo bootstrap (Xcode project, packages, iCloud entitlements, CI) | ✅ 2026-07-10 | ✅ 2026-07-10 |
| M1 — iCloud storage + sync skeleton (VaultKit) | ✅ 2026-07-11 | ✅ 2026-07-11 (two-device sync verified both directions on Mac + iPhone; live conflict drill optional/deferred — machinery unit-tested) |
| M2 — Markdown editor, Liquid Glass (MarkdownKit + EditorKit) | ✅ 2026-07-11 | ✅ 2026-07-11 (checkbox + full marker hiding fixes applied; Writing Tools absent system-wide on this beta — revisit on next macOS 27 seed) |
| M3 — Inline todos + index + master To-Do list (IndexKit + TaskEngine) | | |
| M4 — Todo depth: recurrence, dates, labels, filters | | |
| M5 — Import/conversion pipeline (File-Parser/Docling reuse) | | |
| M6 — AI features (Apple Intelligence / Ollama) | | |
| M7 — Project management / Gantt (ProjectKit) | | |
| M8 — Security hardening (SecurityKit) | | |
| M9 — Platform surfaces (widgets, Shortcuts, share ext, Watch) | | |
| M10 — Release: signed + notarized .app in .dmg, TestFlight | | |

## Pass log

| # | Date | Step | Result | Notes |
|---|---|---|---|---|
| — | 2026-07-10 | scaffold | ✅ | Loop contract written; awaiting research workflow + PLAN.md |
| — | 2026-07-10 | research + plan | ✅ | 12-agent workflow done: RESEARCH.md (10 sections), FEATURES.md, PLAN.md (68 checkbox steps, M0–M10). Paused at pre-build checkpoint. |
| 1 | 2026-07-10 | M0.1 repo init + .gitignore/LICENSE/README | ✅ | git init -b main, remote → rchaight/notetaker; docs included in initial commit |
| 2 | 2026-07-10 | M0.2 Xcode project (XcodeGen) | ✅ | macOS build green. Ad-hoc signing (no Apple Development cert yet — user must sign into Xcode before M1). iOS sim platform installed; iOS Simulator build green. |
| 3 | 2026-07-10 | M0.3 ten local packages + stub tests | ✅ | 10/10 `swift test` pass; app builds on macOS + iOS Simulator with all packages linked |
| 4 | 2026-07-10 | M0.4 SPM deps: swift-markdown → MarkdownKit, GRDB → IndexKit | ✅ | Deps resolved and exercised by tests (parse blocks; in-memory SQLite query) |
| 5 | 2026-07-10 | M0.5 app shell: adaptive tabs + NavigationSplitView + Settings | ✅ | Builds green macOS + iOS Simulator; Liquid Glass from 26 SDK |
| 6 | 2026-07-10 | M0.6 sandbox + hardened runtime + NSUbiquitousContainers | ✅ | Launch-verified on macOS; entitlements confirmed in signed binary. iCloud container entitlement deferred to M1 (needs real cert). |
| 7 | 2026-07-10 | M0.7 CI (GitHub Actions) + CLAUDE.md + SwiftFormat | ✅ | ci.yml: package tests + both-platform builds + format lint on macos-26 runner; repo formatted clean locally |
| 8 | 2026-07-10 | M0.8 push + first CI + branch protection | ✅ | Pushed to rchaight/notetaker; CI run #1 green (build-and-test + format). Protection 403: private repo on Free plan — user decision. |
| 9 | 2026-07-10 | M0 done-criteria verify | ✅ | App launches on macOS (sandboxed) and iOS Simulator (iPhone 17 Pro). iCloud container provisioning deferred to M1 (needs Xcode sign-in). **M0 COMPLETE — checkpoint.** |
| 10 | 2026-07-10 | ENV: switch to Xcode 27 beta (user directive) | ✅ | Builds + 10/10 package tests green on macOS/iOS 27 SDKs. Diagnosed intermittent codesign "detritus" failures → iCloud-synced ~/Documents decorating in-repo build artifacts; all build output moved to ~/.cache/notetaker-build. |
| 11 | 2026-07-10 | M1 gate: real signing + iCloud entitlements live | ✅ | Apple Development cert auto-minted via -allowProvisioningUpdates; device + App ID + container iCloud.com.rchaight.notetaker registered; CloudDocuments/ubiquity entitlements verified in binary; launch OK. M0 fully done incl. deferred container provisioning. |
| 12 | 2026-07-10 | M1.1 VaultKit: ubiquity container + NSMetadataQuery observer | ✅ | UbiquityContainer.documentsURL, VaultItem + DownloadState mapping, MetadataQueryObserver → AsyncStream snapshots. 9 unit tests (pure parts); live-container runtime proof lands with M1.6 debug harness. |
| 13 | 2026-07-10 | M1.2 coordinated I/O + presenter + debounce | ✅ | VaultFileStore (coordinated read/write/delete/move, startDownloading), VaultPresenter (NSFilePresenter → change stream), Debouncer actor. 17/17 tests. One Swift 6 isolation fix (nonisolated let). |
| 14 | 2026-07-10 | M1.3 folder CRUD + external-mutation tolerance | ✅ | createFolder, folder move-with-contents, VaultEnumerator tree snapshots (skips vanished items/dangling symlinks); uncoordinated external deletion leaves store usable. 23/23 tests. |
| 15 | 2026-07-10 | M1.4 conflict detection + keep-both resolution | ✅ | ConflictNaming (sibling-pattern detect, collision-safe keep-both names), VaultConflictCenter over NSFileVersion, coordinated copy(). 30/30 tests; live conflict exercise in M1.6 two-device matrix. |
| 16 | 2026-07-10 | M1.5 DispatchSource tree watcher + security-scoped bookmarks | ✅ | DirectoryWatcher (per-directory sources, self-refreshing watch set, event-driven test passes); VaultBookmark make/resolve/withAccess with unsandboxed fallback. 33/33 tests. |
| 17 | 2026-07-10 | M1.6 debug harness + REAL-container smoke | ✅ | Settings→Vault live browser (download badges, keep-both button, create/delete). Headless smoke vs real ubiquity container: **VAULT SMOKE OK** (write/read/enumerate/delete round-trip). iOS build green. **M1 automatable steps done — checkpoint: two-device matrix needs user's iPhone.** |
| 18 | 2026-07-11 | FIX: Vault harness invisible on iPhone (user-reported at checkpoint) | ✅ | Vault tab added to the main shell on all platforms (#if DEBUG); removed desktop-sized frame. Verified visually in iOS Simulator screenshot. |
| 19 | 2026-07-11 | M1 CLOSED at checkpoint | ✅ | User verified two-device sync both directions (Mac ↔ iPhone 16 Pro Max, real iCloud). Device install required GUI run (xcodebuild CLI can't see Xcode account session) + verification unblock (VPN/Private Relay + restart). **M1 COMPLETE.** |
| 20 | 2026-07-11 | M2.1 MarkdownKit: document model + styling ranges | ✅ | MarkdownDocument (frontmatter split/round-trip, shallow k:v), MarkdownStyler → UTF-16 NSRanges via UTF-8→UTF-16 SourceConverter (emoji-safe), MarkupWalker covering headings/strong/em/strike/code/links/quotes/tasks/tables. 13/13 tests. |
| 21 | 2026-07-11 | M2.2 EditorKit: TextKit 2 editor + theme + live highlighter | ✅ | MarkdownTheme (kind→attributes, heading scales, mono code), MarkdownHighlighter (attribute-only, never mutates chars), MarkdownEditor NS/UIViewRepresentable (TextKit 2, restyle every keystroke, undo, no smart quotes). 8/8 tests; both app builds green. |
| 22 | 2026-07-11 | M2.6 Notes tab: vault list + editor wired (reordered before 2.3–2.5 for user value) | ✅ | NotesModel (live vault list, coordinated load, 800ms debounced autosave, create/delete, LOCAL-VAULT FALLBACK when iCloud off) + NotesView (split view, ⌘N, context delete, fallback banner). Sim screenshot verified; Mac app reinstalled to /Applications. |
| 23 | 2026-07-11 | M2.3 Live Preview: syntax hiding off cursor line | ✅ | SyntaxMarkers (pure marker math: #/**//~~/`/link plumbing, emoji-safe, 7 tests) + hiddenMarkerAttributes + cursor-paragraph tracking with restyle-on-paragraph-change, both platforms. 30 MarkdownKit+EditorKit tests. Mac app refreshed. |
| 24 | 2026-07-11 | M2.4 editor chrome: mode toggle + glass capsule | ✅ | Source Mode ↔ Live Preview toolbar toggle (⌘/), Liquid Glass word-count capsule (glassEffect .capsule). Both builds green; Mac app refreshed. Full macOS CommandGroup menus deferred to M9. |
| 25 | 2026-07-11 | M2.5 Writing Tools enabled | ✅ | writingToolsBehavior = .complete on NSTextView + UITextView (TextKit 2 gives the rest). User-verifiable: right-click → Writing Tools on Mac. |
| 26 | 2026-07-11 | M2.7 performance: benchmark + keystroke debounce | ✅ | 50k-word styling benchmark (~150ms debug, guarded <3s in CI); restyles debounced 150ms above 20k chars on both platforms (small notes stay instant). One patch-miss fix on the iOS coordinator. |
| — | 2026-07-11 | **M2 COMPLETE — checkpoint** | ✅ | 7/7 plan steps done (passes 20–26). Deferred within-milestone: Focus Mode, NSUserActivity restoration, macOS CommandGroup menus (→ M9), visible-range styling (until real lag observed). |
| 27 | 2026-07-11 | FIX (M2 checkpoint feedback): hide ALL markers in Live Preview | ✅ | Blockquote '>' prefixes (incl. nested, deduped), fenced-code ``` lines, list bullets '- '/'1. ' now hide off-cursor-line; unchecked '[ ]' styled accent (visible as UI, interactive in M3). 37 tests. Awaiting user word on whether Writing Tools menu is missing. |
| 28 | 2026-07-11 | FIX (M2 checkpoint feedback): clickable task checkboxes | ✅ | TaskCheckboxes (token find + toggle, 5 tests) pulled forward from M3; token styled semibold-mono accent; click via .link intercept (macOS, undo-safe insertText) / targeted tap gesture (iOS). 44 tests total. |
| 29 | 2026-07-11 | M2 checkpoint closed: Writing Tools diagnosed as OS-level | ✅ | Missing in TextEdit too → macOS 27 beta seed issue, not app code (FoundationModels reports model AVAILABLE — M6 AI features unaffected). isRichText experiment reverted. Checkbox + marker-hiding fixes user-approved. **M2 reviewed ✓.** |
| 30 | 2026-07-11 | M3.1 IndexKit: GRDB schema + migrator + FTS5 | ✅ | Note/Task/TaskLabel/OutLink records, cascade deletes, noteFTS (BM25 search, replace-on-update), user_version guard → wipe+rescan on mismatch, wipeAllRows. 6 tests incl. mismatch-wipe. |
| 31 | 2026-07-11 | M3.2 inbound pipeline: scan → parse → index | ✅ | NoteScanner (tasks w/ line numbers, wikilinks, tags — 5 tests), TaskTokenParser (>dates incl. weekday-next, !p1–4/high/med/low, #labels — 6 tests, THE one parser for all surfaces), NoteIndexer (SHA-256 skip, transactional upsert, remove, rescan-converges — 6 tests). |
| 32 | 2026-07-11 | M3.3 outbound toggle primitive | ✅ | TaskLineToggler: flip at anchor line, relocate moved lines by exact rawLine match, refuse on content drift, byte-exact elsewhere. 5 tests (42 total in MarkdownKit). |
| 33 | 2026-07-11 | M3.4 TaskEngine smart buckets | ✅ | SmartBuckets: overdue/today/upcoming/inbox by ISO due date, day-boundary safe, garbage dates → inbox (never dropped), isoDay helper. 10 TaskEngine tests. |
| 34 | 2026-07-11 | M3.5 master To-Do tab live end-to-end (+ M3.6 smart views) | ✅ | VaultIndexService (root resolve + fallback, on-disk index, incremental reindex, prune, placeholder-safe, toggle via TaskLineToggler + coordinated IO), TodoView (Overdue/Today/Upcoming/Inbox sections, priority colors, tap-to-complete). TWO BUGS FOUND+FIXED in verify: double-start race on shared DB; metadata-snapshot-driven prune wiped index on local vaults (observers are now triggers only; disk enumeration is authoritative). Sim DB verified: tasks/labels/FTS correct and persistent. |

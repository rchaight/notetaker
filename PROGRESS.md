# Notetaker — build-loop progress log

Loop-engineering state file. Read this + PLAN.md at the start of every pass.

## Loop contract

- **Trigger** — self-paced: passes chain immediately (~60s) inside a milestone; the loop BREAKS at every milestone boundary and waits for user review before entering the next milestone.
- **Termination** — all PLAN.md steps checked AND verify green (build + tests + functional exercise of every component) AND user accepts the final composed version. Breaker: 3 consecutive failed passes → notify + halt.
- **State** — PLAN.md checkboxes = cursor · this file = log/streak · git commits = accumulator. One commit per pass containing the code change AND its checked box (atomic progress).
- **Work per pass** — exactly one PLAN.md step: implement → verify → commit.
- **On failure** — append a log row, streak +1, back off (60s → 270s → 1200s). Only success checks a box and resets the streak. At streak 3: push notification, halt, await user input.

## Current state

- **Phase**: building — M2 (Markdown editor) in progress
- **Current milestone**: M2 — MarkdownKit + EditorKit
- **Failure streak**: 0
- **Awaiting user checkpoint**: no
- **Branch protection**: proceeding unprotected (private repo, GitHub Free; no user objection at checkpoint — revisit anytime)
- **Environment note**: toolchain = **Xcode 27.0 beta** (`DEVELOPER_DIR=/Applications/Xcode-beta.app`, macOS/iOS 27 SDKs, iOS 27 sim runtime installed) per user directive. Deployment floor 26.0 until a 27-only API is needed. Developer ID cert present (team 6A2NHN89Q8). ⚠️ Repo is inside iCloud-synced ~/Documents — ALL build products must use external paths (see CLAUDE.md).

## Milestone checkpoints

| Milestone | Completed | User reviewed |
|---|---|---|
| M0 — Repo bootstrap (Xcode project, packages, iCloud entitlements, CI) | ✅ 2026-07-10 | ✅ 2026-07-10 |
| M1 — iCloud storage + sync skeleton (VaultKit) | ✅ 2026-07-11 | ✅ 2026-07-11 (two-device sync verified both directions on Mac + iPhone; live conflict drill optional/deferred — machinery unit-tested) |
| M2 — Markdown editor, Liquid Glass (MarkdownKit + EditorKit) | | |
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

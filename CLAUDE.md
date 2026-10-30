# Notetaker — agent guide

Native macOS 26+/iOS 26+ universal SwiftUI app: markdown notes + inline todos + project management, everything stored in iCloud. Read FEATURES.md (design decisions) and PLAN.md (milestones) before nontrivial work; log build-loop passes in PROGRESS.md.

## The one invariant

**Plain `.md` files in the iCloud Drive vault are the single source of truth. The GRDB index (IndexKit) is derived and must always be rebuildable from the files.** Never write app state that cannot be reconstructed by re-scanning the vault. UI task mutations (check-off, reschedule) edit the source markdown line via coordinated file writes — never only the index.

## Architecture / module boundaries

App target:

- `App/` — shell, feature surfaces, and the wiring that composes packages. Domain logic belongs in a package; what lives here should be UI or glue.
  - `Shell/` — `AppShell` (adaptive TabView + NavigationSplitView), command palette, global hotkey, menu-bar quick add, Settings.
  - `Notes/`, `Todo/` (incl. Meetings), `Projects/` — the feature surfaces.
  - `Calendar/` — the Calendar tab.
  - `Services/` — app-level services: `VaultIndexService`, `VaultRegistry`, `CalendarService` (EventKit), headless vault writer, task/tag extras stores.
  - `Intents/`, `Debug/`.
- `Shared/` — app-group constants shared with the widget extension.
- `Widgets/` — `NotetakerWidgets` WidgetKit extension (Today's Tasks).

Packages:

- `Packages/VaultKit` — iCloud Drive file layer: NSFileCoordinator/NSFilePresenter, NSMetadataQuery observation, conflict detection. Owns ALL file I/O. Also `ReplicaExporter` (builds the filtered replica image and manifest).
- `Packages/MarkdownKit` — swift-markdown parsing/AST, frontmatter, todo/tag/wikilink extraction, style ranges, + `ExportPolicy` (the remote-export gate: decides what may leave the Mac). Pure; no I/O.
- `Packages/EditorKit` — TextKit 2 live-preview editor (NS/UIViewRepresentable), Liquid Glass chrome, heading folding.
- `Packages/IndexKit` — GRDB derived index + FTS5. Rebuildable; schema-version guard drops + rescans.
- `Packages/TaskEngine` — dates, priorities, recurrence, token parsing (ONE engine for every surface), filters. Pure; no I/O.
- `Packages/CalendarKit` — calendar snapshot model, agenda grouping, range arithmetic. Pure; no I/O; EventKit stays in App/Services/CalendarService.
- `Packages/ProjectKit` — projects/Gantt/dependencies as views over TaskEngine + IndexKit data.
- `Packages/ConversionKit` — import pipeline (Vision/Speech native paths; Docling via File-Parser on macOS).
- `Packages/AIKit` — `AIProvider` protocol: FoundationModels | Ollama | None. Private/on-device by default.
- `Packages/SecurityKit` — app lock (LocalAuthentication), per-note locking, Keychain.
- `Packages/AppIntentsKit` — App Intents (Add Task / Create Note) feeding Siri/Shortcuts/widgets.
- `Packages/MCPKit` + the `notetaker-mcp` target (macOS only) — bundled read-only stdio MCP server (Claude Code/Desktop) over the vault + GRDB index, with scan fallback and locked-note redaction, + opt-in calendar snapshot tools (`calendar_agenda`, `calendar_list`; the app writes `Index/calendar-snapshot.json` only while Settings › Calendar sharing is on).
- `Packages/RemoteServer` → the `notetaker-remote` binary (Linux, container-hosted, never shipped in the .app): read-only HTTP MCP server over a pushed replica of the vault, plus the OAuth authorization server (Google login, one allowlisted account, pre-registered client). Opt-in remote vault for claude.ai; see "Remote vault" below.

Dependencies point downward only (App → packages; packages never import App). Pure packages (MarkdownKit, TaskEngine) must stay I/O-free.

## Remote vault (opt-in, off by default)

Settings › Remote → `App/Services/RemoteReplicaService` → `ReplicaExporter` (gated by `ExportPolicy`) → rsync over ssh to a homelab container → `notetaker-remote` behind Tailscale Funnel → claude.ai. Runbook: `deploy/remote-vault/RUNBOOK.md`; scripts and drills: `scripts/remote-vault/`; design and the accepted residual risks: `specs/remote-vault/00-security-design.md`. Invariants to keep:

- **The replica is derived.** The vault `.md` files stay the only truth; the container's copy and index are rebuildable from a push and deletable at any time. Never make the Mac depend on state that exists only on the container.
- **Locked notes never leave the Mac.** `ExportPolicy` fails closed (locked, `_index.md`, hidden, non-`.md`, excluded folders, `remote: false`); the server's title-only redaction is a second gate, not a substitute. A change to either gate extends its table tests in the same pass.
- **Kill switch.** Mac toggle off = empty push + `DISABLED` marker (server answers `available: false`); container `nr-kill` = Funnel off, stop, wipe tokens/index/replica. Keep both working and drilled.
- **Public URL gate.** Only `/mcp`, `/.well-known/*`, `/authorize`, `/auth/google/callback`, `/consent`, `/token`, `/revoke` are routed publicly (no `/register`, no `/healthz`); exactly the seven `notetaker-mcp` tools, all read-only, none takes a URL or writes. A new route or tool is a security change: update the design doc and `scripts/remote-vault/stage1-check.sh` first.
- **Secrets, never read/print/commit:** `/etc/notetaker-remote/env` (Google client secret) on the container and `~/Library/Application Support/Notetaker/RemoteExport/id_ed25519` (the Mac's push key). The audit log holds no bodies, snippets or tokens and stays that way.

## Task syntax — the domain vocabulary

`TaskEngine/TaskTokenParser.swift` is the ONE parser for inline task tokens. Every surface (editor, quick add, master list, widgets, intents) goes through it — never re-regex tokens locally.

```
- [ ] text >friday !p1 #tag @person ?discuss &every 2 weeks ^id blockedby:^other ✅2026-07-14
```

| token | meaning |
|---|---|
| `>date` | due date; `>today` / `>tomorrow` / `>friday` NL shortcuts |
| `!p1`…`!p4` | priority, 1 highest |
| `#tag` | label — stays in `cleanText`, it reads as content |
| `@person` | assignee / audience; the Meetings surface groups by this |
| `?kind` | **closed vocabulary**: `discuss waiting next someday followup` |
| `&every …` / `&after …` | recurrence rule |
| `^id`, `blockedby:^id` / `depends:^id` | block id + dependencies |
| `✅yyyy-mm-dd` | completed day (Logbook) |

Adding a `?kind` means touching parser, rewriter, style ranges, chips, autocomplete pool, and tests together — the vocabulary is duplicated across those regexes by design, so change them in one pass.

## Build & verify

Two hard environment rules:

1. **Toolchain: Xcode 27 beta.** Prefix every xcodebuild/swift command with `DEVELOPER_DIR=/Applications/Xcode-beta.app` (macOS 27 / iOS 27 SDKs; the App Store Xcode 26.6 at /Applications/Xcode.app is the fallback).
2. **Build products must live OUTSIDE the repo.** This repo now sits at `~/Developer/Notetaker` (not iCloud-synced), but it formerly lived under iCloud-synced `~/Documents`, where the file provider decorated in-repo build artifacts with xattrs mid-build and codesign failed with "resource fork/detritus" errors, intermittently and on random targets. Always pass an external scratch/derived-data path; never create `build/` or `.build/` inside the repo.

- `Notetaker.xcodeproj` is GENERATED — edit `project.yml`, then `xcodegen generate`. Never hand-edit the pbxproj.
- Build: `DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' -derivedDataPath ~/.cache/notetaker-build/DerivedData build`
- iOS: same with `-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` (iOS 27.0 simulator runtime is installed)
- Package tests: `cd Packages/<Kit> && DEVELOPER_DIR=/Applications/Xcode-beta.app swift test --scratch-path ~/.cache/notetaker-build/<Kit>`
- Formatting: `swiftformat --lint .`
- **Linux:** no Docker on the dev Mac, so Linux is verified by the GitHub Actions `linux-packages` job (TaskEngine, MarkdownKit, CalendarKit, ProjectKit, IndexKit, AIKit, MCPKit, RemoteServer on `swift:6.4-noble`); check it when a change touches those packages' portability.
- **Full verify gate (run before every commit): `scripts/verify.sh 3 --install`** — all package tests ×3, both builds, launch check. Cross-module flows belong in IndexKit's PipelineIntegrationTests.
- Deployment floor is 26.0 (runs on 26 and 27, built with the 27 SDK). Raise to 27.0 only when a 27-only API is required — check CI runner Xcode availability first.

## Signing & entitlements

Automatic signing, `DEVELOPMENT_TEAM 6A2NHN89Q8`. Apple Development certs are installed on this machine and the iCloud container `iCloud.com.rchaight.notetaker` (CloudDocuments + CloudKit) is enabled in both app entitlement files — M1's old ad-hoc/no-cert blocker is gone. A Developer ID Application cert exists for eventual .dmg distribution (M10, deferred).

## Known traps

- **macOS beta toolbar bridge.** Under the custom macOS shell, `.toolbar` / `.navigationTitle` / `.searchable` / `.inspector` on detail panes crash or render as an opaque black strip over content. The working pattern: build the header in-content (plain VStack, opaque window background + Divider, no translucent material, no `safeAreaInset`). The main window uses `.windowStyle(.hiddenTitleBar)` on its `WindowGroup`; **never** use `.toolbar(.hidden, for: .windowToolbar)` — on this beta it hides the whole `NSTitlebarContainerView`, traffic lights included (spec `specs/calendar/01-window-chrome.md`). Don't reach for the SwiftUI modifier and hope.
- **iCloud xattrs vs codesign** — see Build & verify rule 2.
- **`Notetaker 2/3/4.xcodeproj`** are iCloud sync duplicates that got committed. Ignore them; only `Notetaker.xcodeproj` is real — and it is generated.
- **`_index.md` files are app-generated.** Written per-folder by `VaultIndexService` as machine-readable tables of contents for AI assistants; treat them as derived output, never edit by hand, and never add them to the notes list, search, or the To-Do index — they're excluded at the `VaultFileStore` enumeration choke point on purpose.
- **`/usr/bin/rsync` on macOS is openrsync.** The remote push uses only `-rlt --delete --timeout --exclude/filters -e` (pass 2: `-lt`); the rsync path is a setting so Homebrew's rsync can be used. Don't add flags openrsync lacks without testing both.
- **`verify.sh` tests every `Packages/*/`, including `RemoteServer` (Hummingbird).** It must keep building and testing on macOS although it ships on Linux only.
- **No Docker on the dev Mac** — see the Linux bullet under Build & verify.

## Current phase

M1–M9.7 are built. **M10 (release) is deferred by user decision** — the project is in the **M9.9 ongoing shakedown** phase: the user drives it from day-to-day use, and their bug reports and requests jump the queue. Pick up PLAN.md milestone steps only when nothing is reported and the user asks for plan work; release work waits for an explicit go.

## Build-loop conventions

One step per pass: implement → verify (build/test/launch, not just compile) → one commit containing the code AND a PROGRESS.md pass-log row (plus the checked PLAN.md box, for plan steps). Break at milestone boundaries for user review. Plan-step commits start with `M<n>.<step>:`; shakedown work uses a descriptive prefix (`Editor:`, `Meetings:`, `FIX:`).

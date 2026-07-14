# Notetaker — Implementation Plan (PLAN.md)

> Native macOS 27 + iOS 27 universal SwiftUI app. Markdown-first notes stored as real `.md` files in iCloud, with an inline-todo → master-task engine, an import/conversion pipeline reusing File-Parser/Docling, a private-by-default AI layer, and a project/Gantt view on top. This document is the build order for a solo developer working with Claude Code. Today: 2026-07-10. Repo: `rchaight/notetaker` (empty).

---

## PART 1 — ARCHITECTURE

The order of the sections below matters: storage is decided first because it is the hardest thing to retrofit, and every later subsystem (index, editor writes-back, todos, PM, AI) is a consumer of it.

### 1.1 Chosen architecture (one-paragraph summary)

One universal SwiftUI **app target** for macOS 27 + iOS 27 (NavigationSplitView shell — NOT `DocumentGroup`), plus a **macOS-only XPC helper target** that hosts the Python/Docling conversion engine, plus a set of **local Swift packages** for the reusable subsystems. Notes are plain CommonMark/GFM **`.md` files** living in the app's **iCloud Drive ubiquity container under `Documents/`** (made user-visible in Files.app/Finder via the `NSUbiquitousContainers` Info.plist key) — the single source of truth. A **local, disposable GRDB + FTS5 index** derives todos, tags, backlinks, projects and Gantt schedule from those files and is fully rebuildable by re-scanning the vault. All AI runs through a **provider protocol** (Apple Foundation Models → Ollama → deterministic None), on-device by default.

### 1.2 App targets & platforms

| Target | Type | Platforms | Purpose |
|---|---|---|---|
| `Notetaker` | App | macOS 27, iOS 27, iPadOS 27 (visionOS via iPad compat, no native work) | The universal SwiftUI app shell + all UI. |
| `NotetakerShareExtension` | App Extension | macOS, iOS | Share sheet → new/append note or import inbox. |
| `NotetakerWidgets` | WidgetKit ext | macOS, iOS | Today's Tasks, Quick Note, Control Center control (later milestones). |
| `ConversionHelper` | XPC service (bundled) | **macOS only** | Sandboxed, network-denied host for the Docling/Python engine (import safety). |

Single app target with `#if os(macOS)` / `#if os(iOS)` conditionals; no separate Mac/iOS codebases. Deployment targets: macOS 27.0, iOS/iPadOS 27.0 (Foundation Models, SpeechAnalyzer, Vision `RecognizeDocumentsRequest`, Liquid Glass, App Intents 2.0 all require the 26/27 baseline — do not attempt to support older OSes).

### 1.3 Storage design — `.md` in iCloud + derived index, kept consistent

**Source of truth:** each note is one `.md` file in the ubiquity container's `Documents/` subtree. Folder structure on disk = the vault's folder tree in the UI (Obsidian model). Info.plist gets `NSUbiquitousContainers` → `<container-id>` → `NSUbiquitousContainerIsDocumentScopePublic = true`, `NSUbiquitousContainerSupportedFolderLevels = Any`, so the whole vault is browsable/editable in Files.app and Finder and by other apps (real Obsidian, a text editor).

**Never use `DocumentGroup`** — it is one-window-per-document with no persistent chrome and cannot host a vault sidebar, master To-Do tab, or project view. Build a custom `NavigationSplitView` shell and do all file access directly:
- **Enumerate/observe** the vault with `NSMetadataQuery` (`NSMetadataQueryUbiquitousDocumentsScope`) — surfaces external edits and per-file download state (`.icloud` placeholders, not-yet-materialized items). Drive materialization with `startDownloadingUbiquitousItem`.
- **Every read and write** goes through `NSFileCoordinator` with an `NSFilePresenter` so we never read a half-synced file or race an external writer. On macOS add a `DispatchSource` file-watch as a belt-and-suspenders complement.
- **Offline** writes queue in iCloud Drive and reconcile on reconnect — free from the platform.

**Derived index (rebuildable cache):** a local **GRDB/SQLite** database, NOT authoritative. It holds parsed todos, tags, backlinks, project/Gantt rollups, FTS5 full-text, and a per-file `mtime`+`SHA-256` table for incremental reindex. Rationale for GRDB over SwiftData: the store is disposable (SwiftData's persistence guarantees add little), FTS5 is native in GRDB and absent in SwiftData, and `DatabaseMigrator` gives predictable, testable, ordered migrations for a schema that will churn as task/Gantt features grow. SwiftData is reserved only for a possible future CloudKit-backed *settings* store.

**Consistency protocol (the core correctness contract):**
- **File → index (inbound):** on `NSMetadataQuery`/file-watch change → coordinated read → parse frontmatter + inline tasks with `swift-markdown` (cmark-gfm AST) → upsert rows keyed by stable note id + content hash. Skip files whose `mtime`+hash are unchanged. Debounce iCloud's chatty notifications (~300–500 ms coalescing).
- **Index → file (outbound, e.g. checkbox toggled in master list):** never blind-write. Coordinated read of the current file → locate the exact task line via a **durable inline task id** (hidden marker, see 1.7) with a byte-range/line-anchor cache and a fuzzy-rematch-on-hash fallback if the marker was stripped by another editor → flip `- [ ]`↔`- [x]` (or edit the token) → coordinated write. The DB row is *provisional* until the inbound watcher re-reads the file and confirms.
- **Conflicts:** detect with `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` and `*conflicted copy*` siblings. Surface a resolve UI (keep-both / choose / attempt 3-way text merge for Markdown); never silently auto-merge on heavy simultaneous edits. Because the DB is derived, a lost/corrupt DB is never data loss — "delete DB, re-scan vault" always converges.

### 1.4 Module / package layout (`rchaight/notetaker` repo)

Local Swift packages under `Packages/`, referenced by the app target. Keeps the coding-agent's blast radius small and each subsystem independently testable.

```
notetaker/
├─ Notetaker.xcodeproj (or Package-based app via Xcode 26 workspaces)
├─ App/                         # the universal app target (thin: wiring + SwiftUI shell)
│  ├─ NotetakerApp.swift        # @main, NavigationSplitView shell, scene wiring
│  ├─ Shell/                    # sidebar, note list, tab bar (Notes/To-Do/Projects)
│  └─ Resources/                # Info.plist, entitlements, assets
├─ Extensions/
│  ├─ ShareExtension/
│  └─ Widgets/
├─ Helpers/
│  └─ ConversionHelper/         # macOS XPC service embedding Docling
├─ Packages/
│  ├─ VaultKit/                 # iCloud file store: NSMetadataQuery, NSFileCoordinator,
│  │                            #   NSFilePresenter, download-state, conflict detection
│  ├─ MarkdownKit/              # swift-markdown parse → AST; todo/tag/backlink extraction;
│  │                            #   frontmatter (YAML) read/write; editor styling ranges
│  ├─ EditorKit/                # TextKit 2 NS/UIViewRepresentable live-preview editor,
│  │                            #   Liquid Glass chrome, Writing Tools bridge
│  ├─ IndexKit/                 # GRDB schema + migrations + FTS5; inbound/outbound sync;
│  │                            #   entity types (Note/Task/Project/…); query API
│  ├─ TaskEngine/              # recurrence engine, smart views, date parsing, overdue logic
│  ├─ ProjectKit/              # projects, milestones, dependency graph, critical path, Gantt model
│  ├─ ConversionKit/           # ConversionService protocol; NativeConverter (iOS+mac);
│  │                            #   PythonEngineConverter (mac, talks to XPC helper);
│  │                            #   DoclingServeConverter (HTTP); shared EngineEvent/ExportFormat
│  ├─ AIKit/                    # AIProvider protocol, FoundationModels/Ollama/None providers,
│  │                            #   router, EmbeddingProvider, @Generable schemas
│  ├─ SecurityKit/             # Keychain, LocalAuthentication app lock, CryptoKit locked notes
│  └─ AppIntentsKit/           # AppEntity/AppIntent family, IndexedEntity, Spotlight
└─ scripts/                     # build-dmg.sh, notarize.sh, bootstrap-engine.sh, ci helpers
```

Dependency direction: App → (EditorKit, IndexKit, TaskEngine, ProjectKit, ConversionKit, AIKit, SecurityKit, AppIntentsKit) → (VaultKit, MarkdownKit). No package depends on `App`.

**External SPM dependencies (pin all):** `swiftlang/swift-markdown`, `groue/GRDB.swift`, `mattt/ollama-swift`, `rryam/VecturaKit` (or `swift-embeddings`), and optionally `DlhSoft/Ganttis` (paid, only if interactive Gantt is bought rather than built). Yams (or swift-markdown's own) for YAML frontmatter.

### 1.5 Conversion pipeline — macOS vs iOS (File-Parser reuse)

Root constraint: File-Parser's engine is **pure Python/Docling, macOS-only**; `EngineBridge.swift` uses `Foundation.Process`/`Pipe` which **cannot compile for iOS**. So the pipeline is tiered by platform and connectivity, all behind one protocol.

`ConversionKit` defines `protocol ConversionService { func convert(_ input: URL, to: ExportFormat) -> AsyncStream<EngineEvent> }` emitting the existing NDJSON-style `EngineEvent` progress. Concrete implementations, selected at runtime by a router keyed on input type + platform + reachability:

- **Tier 1 — `NativeConverter` (iOS + macOS, on-device, instant, private, offline):**
  - PDF (born-digital): `PDFKit` `PDFDocument` per-page text.
  - Images/scans + **tables**: Vision `RecognizeDocumentsRequest` (iOS 26+ native table/list detection) + VisionKit `VNDocumentCameraViewController`/`DataScannerViewController` for capture.
  - Audio (MP3/WAV/voice memo): `SpeechAnalyzer` + `SpeechTranscriber` (on-device, long-form) → optional LLM cleanup pass via AIKit.
  - HTML/RTF/plain/CSV/MD: `NSAttributedString` (+ `.html` where supported) → Markdown.
- **Tier 2 — `PythonEngineConverter` (macOS only):** talks to the bundled `ConversionHelper` **XPC service**, which hosts the Docling venv (import safety: sandboxed, no network entitlement, resource/time limits vs decompression bombs). Handles complex PDF + **DOCX/PPTX/XLSX** at full TableFormer fidelity.
- **Tier 2b — `DoclingServeConverter` (iOS + macOS over HTTP):** POSTs to the user's homelab `docling-serve` (`POST /v1/convert/file`, stable v1 API) when reachable, with token auth + TLS. Gives iOS full Docling quality for office formats while data stays on the user's own hardware.
- **Tier 3 — iCloud import-inbox fallback (offline-tolerant catch-all, satisfies the HARD iCloud requirement):** iOS drops any unconvertible source into a `.notetaker/inbox/` folder in the ubiquity container; the Mac app watches it, converts with the full engine, writes the `.md` back into the vault, and it syncs to all devices. Removes any hard dependency on homelab uptime; conversion is eventually-consistent by design.

**File-Parser structural reuse (do first in the import milestone):** refactor File-Parser's `app` executableTarget into a package exposing a **library product** containing `EngineBridge.swift` + `EngineEvent`/`ExportFormat` model types + bootstrap resources; guard the `Process`-based code behind `#if os(macOS)`. Parameterize the hardcoded dev path in `EngineBridge.swift` (lines 42 & 59, `/Users/rchaight/.../File-Parser/engine`). Notetaker bootstraps its **own** venv into its own app-support dir by default (sandbox-clean), honoring an explicit override that points at an existing `~/Library/Application Support/File-Parser/engine`. Reuse `formats.py` `catalog()`/`--list-formats` as the single source of truth for supported formats; `NativeConverter` advertises a reduced capability set so the UI can gray-out/auto-route formats it can't do locally.

### 1.6 Security architecture

- **Hardening:** App Sandbox **and** Hardened Runtime both ON (required together for a notarized universal app). Target **zero** Hardened-Runtime exceptions. The Docling/Python engine is isolated in the `ConversionHelper` XPC service precisely so the main app never needs `allow-jit`/`disable-library-validation`.
- **Entitlements:** iCloud `CloudDocuments` (`com.apple.developer.icloud-services`, `icloud-container-identifiers`, `ubiquity-container-identifiers`); user-selected vault folders `com.apple.security.files.user-selected.read-write` + app-scoped security-scoped bookmarks (`com.apple.security.files.bookmarks.app-scope`, wrap access in `start/stopAccessingSecurityScopedResource()`, re-resolve stale bookmarks to survive the known 2025 macOS FileProvider-drop regression); network client `com.apple.security.network.client` for Ollama/docling-serve; iOS `NSLocalNetworkUsageDescription` only if the endpoint is a LAN/mDNS host.
- **Data at rest:** leave the note store at the iOS default `FileProtectionType.completeUntilFirstUserAuthentication` (encrypted at rest, background sync/index still works); apply `.complete` to the SQLite index of *locked* notes and any decrypted scratch files. On macOS rely on FileVault + per-note encryption.
- **iCloud encryption honesty (critical messaging):** note bodies in iCloud Drive are Apple-key-encrypted by default and become **end-to-end encrypted only if the USER enables Advanced Data Protection** (an OS setting the app cannot toggle). Detect/nudge toward ADP; document the 14→23 E2E-category change; never over-promise default E2E.
- **App lock:** `LAContext` `.deviceOwnerAuthenticationWithBiometrics` (Face/Touch/Optic ID) → fallback `.deviceOwnerAuthentication` (passcode), on launch and on resume. Biometrics gate the *release of a key*, not the key.
- **Per-note Locked Notes (independent of ADP):** PBKDF2-HMAC-SHA256 key derivation from a passphrase → AES-GCM encrypt the body via CryptoKit; store ciphertext + salt + IV in the synced file (plaintext never enters iCloud). Biometrics unlock a Keychain-wrapped copy of the derived key; "secure session" avoids re-prompting for same-passphrase notes. UX must state unmistakably: a forgotten passphrase = unrecoverable (no key escrow).
- **Secrets:** Ollama base URL + token in Keychain as `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (don't propagate a LAN credential via iCloud Keychain).
- **AI privacy tiers (explicit, user-selectable, logged per note):** (1) on-device Apple Foundation Models = default; (2) homelab Ollama = opt-in, data stays on user's hardware, TLS + Keychain token; (3) Private Cloud Compute for long/reasoning tasks (privacy-guaranteed, entitlement required); never third-party cloud unless explicitly opted-in per request.
- **Import/HTML safety:** untrusted HTML previews render in an isolated `WKWebView` with `allowsContentJavaScript = false`, all remote resource loads + navigation blocked via `WKContentRuleList`/CSP, sanitized to a tag allowlist first, never auto-loading remote images (tracking pixels).

### 1.7 Concrete data model (what lives in Markdown vs the derived index)

**Storage split:**
- **YAML frontmatter (travels with file, authoritative for note-level attrs):** `id`, `title`, `tags`, `created`, `modified`, `aliases`, `project`, plus project/milestone declarations for project-home notes.
- **Inline in Markdown body (authoritative for tasks, portable):** `- [ ] Task text >2026-07-15 !high #project/label ^taskid` — GFM checkbox + NotePlan-style `>due`/`>start` (with `>today`/`>tomorrow`/`>friday` NL shortcuts) + `!priority` + `#tag` + optional `depends:`/`blockedby:` + a **durable hidden `^taskid`** so master-list toggles re-target the right line after external reformatting.
- **Index-only (DB, NEVER written back to files):** normalized/parsed columns, FTS5 index, backlink graph, **computed Gantt schedule** (start/finish rollups, critical path — derived, would churn files if persisted), download status, content hashes, cached render, embeddings/vector store.

**Entities (GRDB tables):**
- **Note** — `id`, `filePath` (relative), `title`, `frontmatter` (parsed blob), `contentHash`, `createdAt`, `modifiedAt`, `wordCount`. Has-many Task/OutLink; belongs-to Project (optional). File-authoritative, rebuildable.
- **Task** — `id` (= inline `^taskid`), `noteId` (FK), `lineAnchor`/`byteRange`, `text`, `state` (open/done/cancelled/scheduled/inProgress), `dueDate`, `scheduledDate`, `startDate`, `completedAt`, `priority` (none/low/med/high/urgent ≈ P1–P4), `recurrenceRule` (RFC-5545-ish + mode: fixed vs completion-based), `parentTaskId`, `sortOrder`. M:N → Label. Content file-authoritative; scheduling rollups index-only.
- **Label/Tag** — `id`, `name`, `color`, `kind` (`#tag` / `@context` / project-label). M:N with Note and Task.
- **Project** — `id`, `name`, `noteId` (home note, optional), `status`, `startDate`, `targetDate`, `color`, `description`. Has-many Milestone/Task/DependencyEdge.
- **Milestone** — `id`, `projectId`, `name`, `dueDate` (zero-duration diamond), `state`.
- **DependencyEdge** — `id`, `projectId`, `fromTaskId`, `toTaskId`, `type` (FS default; SS/FF/SF later), `lag`. Index-only, sourced from inline `blockedby:`/`depends:` so portable.
- **OutLink/Backlink** — `id`, `sourceNoteId`, `targetNoteId` (or unresolved string), `context`. Fully derived; powers `[[wikilink]]` graph + backlinks pane.
- **IndexMeta** — `schemaVersion`, `lastFullScanAt`, per-file `mtime`+`hash`.

Gantt schedule is computed by topologically sorting DependencyEdges over Task durations; critical path/slack derived in-index and never persisted to `.md`.

### 1.8 AI provider abstraction

`protocol AIProvider` with async `summarize`, `extractStructured<T>` (guided/`@Generable`-style), `chat`/`stream`, `embed`, and a `Capabilities` descriptor (`maxContextTokens`, `supportsStructuredOutput/Streaming/Vision`, `isReachable`, `isPrivate`). Concrete: **`FoundationModelsProvider`** (wraps `SystemLanguageModel` on-device 4096-tok + `PrivateCloudComputeLanguageModel` 32K), **`OllamaProvider`** (homelab), **`NoneProvider`** (deterministic: `NSDataDetector`/regex task parsing, keyword search). A **router** picks per request from measured `tokenCount(for:)`, task type, availability (`SystemLanguageModel.default.availability`), reachability (cached short-timeout probe), privacy setting, and explicit user preference (Auto / On-device only / Homelab). A separate `EmbeddingProvider` (NLContextualEmbedding default, Ollama optional) keeps semantic search independent of the chat engine. Hard rule: never route inputs >~3k tokens to the on-device model; the note editor never blocks on a network call.

### 1.9 The 5 riskiest technical bets & fallback plans

1. **iCloud Drive file-coordination correctness (highest risk).** The API is low-level, lock/notification-based; half-synced files, `.icloud` placeholders, delayed/chatty notifications, and a 2025 macOS FileProvider-drop regression all bite. *Fallbacks:* build M1 as a standalone harness with a brutal multi-device offline-edit test matrix before any UI; wrap all I/O in one audited `VaultKit` API so fixes are localized; keep the index rebuildable so any coordination bug degrades to "re-scan," never data loss; if iCloud proves unworkable, the `.md`-on-disk + security-scoped-bookmark path still lets a user point at a Dropbox/Obsidian-Sync folder (documented-unsupported but functional).
2. **Markdown conflict merges losing edits.** `NSFileVersion` auto-merge can drop/duplicate content on simultaneous heavy cross-device edits; naive last-writer-wins silently loses data. *Fallback:* never auto-merge silently — surface conflicts with keep-both as the safe default; only offer 3-way text merge as an explicit user action; durable `^taskid` markers keep checkbox toggles addressable so the master list doesn't itself cause spurious conflicts.
3. **Interactive Gantt (drag/resize/dependency-draw/critical-path).** Swift Charts has no Gantt mark and no editing; a custom `Canvas`+gesture implementation is months of work. *Fallback (staged):* ship a **read-only** Swift Charts `BarMark` timeline first (M7a); build the custom interactive `Canvas` layer only if usage justifies it (M7b); if it's a headline feature and time-boxed, **license Ganttis/DlhSoft** SwiftUI wrappers (mac+iOS, drag/resize/dependencies/zoom built-in) — accept the paid-dependency lifecycle risk.
4. **iOS office-format import gap (DOCX/PPTX/XLSX).** No viable native iOS parser exists in 2026. *Fallback:* the three-tier pipeline (1.5) — native-first for capture cases, `docling-serve` when reachable, and the **iCloud import-inbox → Mac converts → syncs back** catch-all that needs no homelab uptime; UI clearly labels "converted on-device (basic)" vs "full Docling" provenance so users understand fidelity.
5. **Apple Intelligence availability + 4096-token wall.** FMF/Writing Tools require eligible hardware; the on-device context can't hold whole notes; PCC free tier is conditioned on <2M downloads + an entitlement; Ollama is often unreachable. *Fallback:* every AI feature gates on `.availability` and degrades to `NoneProvider` (regex/keyword) so the app is fully usable offline and on ineligible hardware; token-budget + engine-routing designed in from M6, not bolted on; treat all AI as enhancement, never a hard dependency; pull Ollama model list dynamically from `/api/tags` so model churn doesn't break the app.

---

## PART 2 — REPO BOOTSTRAP (M0)

**Goal:** an empty `rchaight/notetaker` becomes a buildable, CI-wired universal SwiftUI skeleton that launches an empty NavigationSplitView on Mac and iPhone.

**Ordered steps:**
- [x] `git clone` the empty repo; add `.gitignore` (Swift/Xcode + `*.xcuserstate`, `DerivedData/`, `.venv/`, `.env`), an MIT/personal `LICENSE`, and a `README.md` stub.
- [x] Create the Xcode project/workspace (Xcode 26) with the `Notetaker` universal app target (macOS 27 + iOS 27 deployment). Set bundle id `com.rchaight.notetaker`, enable Automatic signing with the personal team; create the App ID + iCloud container `iCloud.com.rchaight.notetaker` in the developer portal. *(Adapted: XcodeGen-generated project, deployment 26.0 per installed SDK; ad-hoc signing + portal App ID/iCloud container deferred to M1 — needs Xcode Apple ID sign-in, flagged at checkpoint.)*
- [x] Add the empty local packages from 1.4 (`VaultKit`, `MarkdownKit`, `EditorKit`, `IndexKit`, `TaskEngine`, `ProjectKit`, `ConversionKit`, `AIKit`, `SecurityKit`, `AppIntentsKit`) with stub `public` APIs + one passing test each; wire them into the app target.
- [x] Add pinned SPM deps: `swift-markdown`, `GRDB.swift`. (Others added in their milestones.)
- [x] Put `NavigationSplitView` shell in `App/Shell/` with three placeholder tabs (Notes / To-Do / Projects) and a Settings scene. Confirm Liquid Glass appears automatically by compiling against the 26+ SDK.
- [x] Add Info.plist iCloud entitlements + the `NSUbiquitousContainers` key; App Sandbox + Hardened Runtime ON. *(iCloud container entitlement itself deferred to M1 step 1 — requires a real signing cert; sandbox + hardened runtime + NSUbiquitousContainers are in and launch-verified.)*
- [x] Set up **CI** (GitHub Actions, macOS runner): `xcodebuild build test` for both destinations on every PR; SwiftFormat/SwiftLint check. Add a `CLAUDE.md` documenting the architecture, module boundaries, and the "files are truth / index is derived" invariant so the coding agent respects it.
- [x] Branch-protect `main`; work on feature branches → PRs. *(Pushed with CI green; branch protection returned 403 — private repo on GitHub Free. User decision at checkpoint: make public, upgrade to Pro, or proceed unprotected.)*

**Done:** CI green; app launches empty on Mac + iOS Simulator; all packages compile and their stub tests pass; iCloud container provisioned.
**Effort:** ~2–3 days.

---

## PART 3 — MILESTONES

De-risking order is deliberate: **storage/sync first** (hardest to retrofit), then editor, then todos+master list, then import, then AI, then PM/Gantt, then security polish + surfaces, then release.

### M1 — iCloud storage + sync skeleton (VaultKit) — DO FIRST
**Goal:** rock-solid, headless read/write/observe of `.md` files in the iCloud ubiquity container, with conflict detection, provable across two devices offline — before any editor exists.
**Steps:**
- [x] Implement `VaultKit`: open the ubiquity container `Documents/`; `NSMetadataQuery` enumeration + live observation reporting per-item download state.
- [x] Coordinated read/write API (`NSFileCoordinator` + an `NSFilePresenter`); `startDownloadingUbiquitousItem` for placeholders; debounce change notifications.
- [x] Folder CRUD (create/rename/move/delete) mirroring on-disk structure; external-mutation tolerance (files renamed/deleted by Obsidian/Files.app must not crash the observer).
- [x] Conflict detection via `NSFileVersion.unresolvedConflictVersionsOfItem` + `*conflicted copy*` sibling scan; expose a resolve API (keep-both default).
- [x] macOS `DispatchSource` watcher as complement; security-scoped bookmark handling for user-chosen vault roots (with stale-bookmark re-resolution).
- [x] **Test harness:** an XCTest + a tiny debug UI that creates/edits/deletes notes; a manual two-device (Mac + iPhone) offline-edit-then-reconnect matrix; a "delete index, re-scan converges" test. *(Harness + real-container smoke done; two-device matrix = M1 checkpoint with user; index-rescan test lands with IndexKit in M3.)*
**Done:** create/edit/delete a note on Mac, see it on iPhone within seconds and vice versa; induce a conflict (edit same file offline on both) and get a detected conflict surfaced, not silent loss; killing/relaunching mid-sync leaves no corruption.
**Effort:** ~2 weeks (this is the crown-jewel risk; budget generously).

### M2 — Markdown editor (MarkdownKit + EditorKit)
**Goal:** a polished Liquid Glass live-preview CommonMark/GFM editor over real `.md`, with Writing Tools for free.
**Steps:**
- [x] `MarkdownKit`: `swift-markdown` parse → AST; one parse drives both editor styling ranges and (later) todo/tag/backlink extraction; YAML frontmatter read/write.
- [x] `EditorKit`: TextKit 2 `NSTextView`/`UITextView` behind `NS/UIViewRepresentable`; `NSTextStorageDelegate` live syntax styling on every keystroke (headings, bold/italic, lists, tables, code fences + syntax highlight, task checkboxes, blockquotes, links). Study/reuse `nodes-app/swift-markdown-engine` and `Shpigford/clearly`.
- [x] **Live Preview hybrid:** hide markdown syntax markers except on the cursor's line; real `.md` underneath. Source-mode toggle + Focus Mode (fade all but current sentence/paragraph). *(Live Preview + API-level source mode done; UI toggle + Focus Mode land with M2.4 chrome.)*
- [x] Liquid Glass chrome: `glassEffect` + `containerConcentric` toolbars/floating capsules; native menu bar `CommandGroup` (File/Edit/View) on macOS. *(Glass word-count capsule + mode toggle done; full CommandGroup menu deferred to M9 surfaces.)*
- [x] Writing Tools: on a plain TextKit-2 text view it's free; for the custom-styled storage bridge via `UIWritingToolsCoordinator`/`NSWritingToolsCoordinator`. *(writingToolsBehavior = .complete both platforms; coordinator bridge only if styled-storage issues surface in use.)*
- [x] Wire editor ↔ VaultKit: open note = coordinated read; save = coordinated write (debounced/autosave); state restoration via `NSUserActivity` (note + cursor). *(Done except NSUserActivity restoration — deferred to M2 polish.)*
- [x] Performance: incremental/visible-range styling; profile a 50k-word note and a 5k-note vault list (lazy prefetch). *(50k-word parse benchmarked ~150ms debug; keystroke restyles debounced >20k chars. Visible-range-only styling deferred until a real note shows lag.)*
**Done:** open a `.md`, type Markdown, see live formatting; syntax hides off-cursor-line; the underlying file stays valid CommonMark (diff it in Finder); Writing Tools proofread/rewrite/summarize work inside a note; no lag on a large note.
**Effort:** ~2.5–3 weeks.

### M3 — Inline todos + parser/index + master To-Do list (IndexKit + TaskEngine)
**Goal:** inline `- [ ]` todos authored in any note aggregate into a **live bidirectional** master list; checking anywhere edits the exact source line.
**Steps:**
- [x] `IndexKit`: GRDB schema + `DatabaseMigrator` for Note/Task/Label/OutLink + FTS5 virtual table + IndexMeta; schema-version guard with "drop + full-rebuild from files" recovery.
- [x] Inbound sync: on VaultKit change → parse via MarkdownKit → extract todos (`- [ ] text >due !priority #tag ^id`), tags, `[[wikilinks]]` → upsert keyed by note id + hash; skip unchanged files by `mtime`+SHA-256; assign/inject durable `^taskid` markers on first index. *(Pipeline done: NoteScanner + TaskTokenParser + NoteIndexer w/ SHA-256 skip. Live VaultKit wiring lands with the To-Do tab (M3.5); durable ^ids deferred — line anchors first.)*
- [x] Outbound sync: master-list checkbox toggle → coordinated read → locate line by `^taskid` (byte-range cache, fuzzy-rematch fallback) → flip state token → coordinated write → let inbound reconcile. *(TaskLineToggler: anchor line + exact-rawLine relocate + refuse-on-drift; coordinated read/write wiring lands with the To-Do tab.)*
- [x] `TaskEngine`: date parsing (`>today`/`>tomorrow`/`>friday` + absolute), P1–P4 priorities, overdue computation.
- [x] Master To-Do tab UI: live `@Query`-style list (GRDB reactive), native drag-reorder (WWDC26 list reorder), "jump to note" from any row. *(Live list + toggle done via version-counter refresh; drag-reorder and jump-to-note deferred to M3 polish.)*
- [x] Pre-built smart views: **Inbox** (undated), **Today** (due + overdue), **Upcoming**; **Overdue bucket** so past-due never silently vanishes.
- [x] Full-text search UI backed by FTS5 (BM25, phrase/prefix/highlight). *(BM25 + sanitized prefix matching in the Notes list; match highlighting deferred.)*
**Done:** type `- [ ] Buy milk >tomorrow !high` in a note → it appears in Today/Upcoming; check it off in the master list → the note's source line becomes `- [x]` (verify in Finder) and vice versa; an overdue undone task shows in Overdue, never disappears; search finds text across the vault instantly.
**Effort:** ~3 weeks.

### M4 — Todo depth: recurrence, dates, labels, saved filters (TaskEngine)
**Goal:** Todoist/Things-grade todos over the one dataset.
**Steps:**
- [x] **One recurrence engine**, invoked identically from every surface — fixed-schedule AND completion-based ("every 7 days when done"); structurally impossible to mark done without regenerating the next instance (avoid the Dataview footgun).
- [x] NL Quick Add parser as the standard entry path everywhere (one line → date/recurrence/priority/project/labels); `NSDataDetector` baseline, FMF-enhanced in M6.
- [x] Start/scheduled vs due date distinction (optional third Planned date). *(~start + >due shipped; third Planned date deferred until a real need appears.)*
- [x] Free-form Labels as a cross-cutting axis; saved custom Filters (query syntax `priority:P1 AND due:today`) + a visual builder. *(Query grammar + saved filters shipped; visual builder deferred to polish.)*
- [x] In-task nested sub-checkboxes with progress ring; computed relevance/Task Score for auto-sorting undated todos; in-note Completed section. *(Nesting + n/m progress shipped; Task Score needs creation dates (deferred), Completed section deferred to editor polish.)*
- [x] Additional views over the one dataset: Kanban, Calendar, Eisenhower Matrix. EventKit two-way (attach a native Reminder/alert). *(Board/Agenda/Matrix shipped as view switcher; EventKit deferred to M9 system surfaces — permission flows belong together.)*
**Done:** a recurring task regenerates on completion on every surface; a saved filter returns correct rows; sub-checkbox completion drives the parent's progress ring; Kanban/Calendar/Matrix all reflect the same todos live.
**Effort:** ~3 weeks.

### M5 — Import / conversion pipeline (ConversionKit + ConversionHelper)
**Goal:** PDF/DOCX/PPTX/image/audio → Markdown across Mac and iOS via the tiered strategy, reusing File-Parser/Docling.
**Steps:**
- [x] Refactor File-Parser `app` into a library product; guard `Process` code behind `#if os(macOS)`; parameterize the hardcoded engine path (EngineBridge lines 42/59). *(PythonEngineConverter ports EngineBridge's resolution chain (setting → app-support install → dev repo) and drives fileparser.cli directly; live-tested against the installed engine.)*
- [x] `ConversionService` protocol + shared `EngineEvent`/`ExportFormat`; reuse `formats.py catalog()` as the capability source of truth. *(Protocol + result/provenance shipped; EngineEvent/catalog arrive with the Docling tier.)*
- [x] `ConversionHelper` XPC service (macOS): bootstrap own venv into app-support (override honored); sandboxed, network-denied, resource/time-limited. *(SUPERSEDED by architecture decision 2026-07-12: macOS ships unsandboxed (Developer ID .dmg — sandbox optional) so the app drives the engine directly; venv bundling/bootstrap moves to M10 packaging.)*
- [x] `NativeConverter` (both platforms): PDFKit, Vision `RecognizeDocumentsRequest` + VisionKit scanner, `SpeechAnalyzer`/`SpeechTranscriber`, `NSAttributedString` HTML/RTF. *(PDFKit text + OCR-fallback, Vision OCR images, RTF/HTML, txt/md done. AUDIO DROPPED from scope — the user's voicetype.app covers transcription cross-platform (2026-07-12). VisionKit scanner UI deferred.)*
- [x] `DoclingServeConverter` (HTTP to homelab, token+TLS) + reachability probe. *(HTTP + /health probe + Settings URL/test shipped; auth token + TLS pinning when the server side needs it.)*
- [x] Router: pick tier by input type + platform + connectivity; **iCloud import-inbox** fallback (iOS drops source → Mac converts → syncs back). *(Router + import-inbox BOTH shipped: Imports/Inbox/ auto-converts on scan; failures wait for a device that can convert — that IS the iOS→Mac relay.)*
- [ ] Share Extension: send text/URL/file into new/existing note or the inbox. Provenance labeling ("on-device basic" vs "full Docling").
**Done:** on Mac, convert a complex DOCX with tables to faithful Markdown; on iPhone, scan a document and OCR it to Markdown natively, and transcribe a voice memo; drop an office file on iPhone with no homelab → it converts on the Mac and the `.md` appears in the vault everywhere.
**Effort:** ~3 weeks.

### M6 — AI features (AIKit) — private/on-device by default
**Goal:** the `AIProvider` abstraction with Foundation Models + None (MVP), Ollama + PCC (v1), all gated and offline-safe.
**Steps:**
- [x] `AIProvider` protocol + `Capabilities`; router keyed on `tokenCount(for:)`, task type, `SystemLanguageModel.default.availability`, reachability, privacy pref. *(Protocol + availability-ordered router shipped; token-count routing lands with the Ollama tier.)*
- [x] `FoundationModelsProvider`: `@Generable`/`@Guide` guided generation for **NL task parsing** (text → typed `Todo`/date/priority/tags) and **action-item extraction** (note → `[Todo]` inserted as inline `- [ ]`); short summarize; auto-tag/auto-title. Route >~3k-token inputs to PCC/Ollama. *(Parse/extract/summarize shipped, live generation CLI-verified; auto-tag/title + long-input routing with Ollama pass.)*
- [x] `NoneProvider`: `NSDataDetector`/regex task parsing + keyword search fallback (app fully usable on ineligible hardware/offline).
- [x] Semantic search: `NLContextualEmbedding` (256-tok paragraph chunks) → `VecturaKit` local vector store; expose notes/todos as `IndexedEntity` for system Spotlight/Siri semantic search. *(NLContextualEmbedding mean-pooled chunks → GRDB blobs + brute-force cosine (no VecturaKit dep — personal-vault scale); merged after FTS in the search field. IndexedEntity/Spotlight → M9.)*
- [x] `OllamaProvider` (`mattt/ollama-swift`): config UX (prefill `http://<homelab-ip>:11434`, optional Bonjour, `/api/tags` health-check + model picker, Test Connection, persist URL only in Keychain). Long-note summarization, transcript cleanup, project-plan drafting; default Gemma3-12B/Qwen3, tool-calling model for structured extraction. *(Own thin client (no dep): /api/chat + JSON-schema structured extraction, /api/tags probe + model picker, size-aware routing >3k tokens. Bonjour + Keychain storage deferred; URL in defaults for now.)*
- [ ] PCC `.deep` tier (32K, entitlement) for long/reasoning tasks. Per-note AI-tier indicator + logging; AI-authorship provenance marking.
**Done:** type "call Bob fri 3pm !p1" → structured task created on-device; "extract action items" on a note inserts real inline todos; semantic search returns meaning-matched notes; with homelab reachable, a long note summarizes via Ollama and falls back cleanly to PCC/None when it isn't; on an ineligible device every AI button degrades gracefully.
**Effort:** ~3 weeks (MVP slice: FMF + None + embeddings; defer Ollama/PCC polish if needed).

### M6.5 — Editor visual polish (user-selected 2026-07-12, before M7)
**Goal:** Bear/Craft-grade editor visuals over the same plain-markdown storage. Ordered by effort; one checkbox per pass.

- [x] Wikilink + `==highlight==` styling: `[[wikilinks]]` accent+underline, highlight runs get marker-pen tint (attributes-only).
- [x] Word count / reading time chip on the editor; reflects selection when non-empty.
- [x] Token-based theme palette: named tokens (bg/surface/accent/text tiers/code-bg/quote-accent), OLED-safe dark values.
- [x] Focus dimming: non-cursor paragraphs dim to secondary color, toggleable from the format bar.
- [x] Blockquote accent bar: indent + tint via paragraph style, true left bar via fragment drawing.
- [x] Horizontal rules render as real divider lines off-cursor (equal-length substitution/attachment).
- [x] Inline image thumbnails: `![alt](path)` shows async-loaded preview attachment; storage keeps literal markdown.
- [x] Code block cards: full-width rounded tinted card + language badge via NSTextLayoutFragment custom drawing.
- [x] Table grid rendering (full): bordered grid presentation for markdown tables; fall back to raw text on the cursor's table.

### M6.6 — Notes organization (user-selected feature queue, before M7)
**Goal:** the 11 chosen organization features (backlinks panel + TOC shipped earlier).

- [x] Nested tag tree: schema v6 noteTag table; sidebar Tags section with per-level counts; tag tap filters the note list.
- [x] Tag + [[wikilink]] autocomplete while typing in the editor.
- [x] Sidebar sections: Pinned notes, Recents, Bookmarks.
- [x] Saved smart searches (persisted search queries as sidebar entries).
- [x] Daily note spine (Today note command + calendar navigation).
- [x] Note templates (template files with placeholders).
- [x] Multi-vault switcher.

### M7 — Project management / Gantt (ProjectKit)
**Goal:** PM as another view over the same todos + frontmatter, not a second data model.
**Steps (staged for de-risking):**
- [x] Project = a note with frontmatter (`status`/`start`/`due`/`project`); its tasks are the inline todos referencing it. Milestones as zero-duration diamonds.
- [x] `ProjectKit`: DependencyEdge graph sourced from inline `blockedby:`/`depends:`; topological schedule computation; auto-% complete from checked child todos (Linear-style); ungated critical-path + slack (never paywalled).
- [x] **M7a — read-only timeline:** Swift Charts `BarMark` per task (x-range start→end) vs categorical task axis; day/week/month zoom; lightweight roadmap default for small projects.
- [x] **M7b — interactive Gantt:** *(drag-move + edge-resize on bars; dependencies via Blocked By context menu — deliberate substitution for draw-a-line, more reliable on the beta; cascade recomputes automatically on reindex)* custom `Canvas`+gesture layer for drag-move/resize-duration, draw-a-line finish-to-start dependencies with auto-cascade + downstream-impact indicator. *If time-boxed:* license Ganttis instead.
- [x] Alternate Kanban + canvas/board view per project; "graduate" roadmap → full Gantt.
**Done:** a project note's inline todos render as Gantt bars; checking off children updates % complete automatically; the critical path highlights with no paywall; (M7b) dragging a bar reschedules and cascades dependents.
**Effort:** M7a ~1.5 weeks; M7b ~3–4 weeks (or ~1 week if licensing Ganttis).

### M7.5 — To-Do UX upgrades (user-selected 2026-07-12, all 12 research items; after M7)
- [x] Completion fade: strike + ~0.4s fade before leaving the list.
- [x] Row density setting (Compact/Comfortable/Relaxed), persisted.
- [x] Jump-to-note from any task row.
- [x] Priority/label color chips consistent across List/Board/Agenda/Matrix (+ per-label colors).
- [x] "Set due date" + "delete line" write mutations (shared engine for the next two).
- [x] Swipe actions (iOS): complete / snooze-to-tomorrow / delete.
- [x] Drag-to-reschedule cards across date sections (Agenda/Board).
- [x] Multi-select + batch edit (priority/label/date/complete).
- [x] AI-powered Quick Add via existing FoundationModels provider (offline fallback = current parser).
- [x] Logbook: ✅YYYY-MM-DD completion token on toggle + completed view grouped by day.
- [x] Streak/karma strip (local-only, opt-in; builds on the Logbook token).
- [x] Command palette (⌘K): quick add, jump to filter/note, switch views.
- [ ] Menu bar quick-add (macOS MenuBarExtra + hotkey; pulled forward from M9).

### M8 — Security hardening (SecurityKit)
**Goal:** app lock + per-note Locked Notes + honest encryption posture.
**Steps:**
- [ ] App lock: `LAContext` biometrics → passcode fallback, on launch + resume; grace-period setting.
- [ ] Locked Notes: PBKDF2-HMAC-SHA256 → AES-GCM (CryptoKit); ciphertext-only in synced file; Keychain-wrapped derived key released by biometrics; shared-passphrase secure session; unrecoverable-passphrase warning UX.
- [ ] Keychain for Ollama endpoint/token (`ThisDeviceOnly`).
- [ ] ADP detection + nudge; per-note AI-tier disclosure; WKWebView HTML sanitization/JS-off/remote-block for imported HTML previews.
- [ ] Verify App Sandbox + Hardened Runtime with zero exceptions across app + extensions + XPC helper.
**Done:** app requires Face ID on launch; a locked note stores only ciphertext in iCloud (verify in Finder) and opens with biometrics; forgetting a per-note passphrase is clearly flagged as permanent; notarization dry-run passes with no runtime-exception smells.
**Effort:** ~1.5–2 weeks.

### M9 — Platform surfaces & integrations (AppIntentsKit + Widgets)
**Goal:** highest-ROI system integration, built on App Intents 2.0 (SiriKit deprecated).
**Steps:**
- [ ] One `AppIntent` family ("Add Task"/"Create Note") + `AppEntity` for notes/todos → feeds Siri, Spotlight, Shortcuts, Control Center simultaneously. `IndexedEntity` + CoreSpotlight (capped, deduped subset — FTS5 stays primary search).
- [ ] Home/Lock Screen interactive widgets: "Today's Tasks" (check off inline via `AppIntent`), "Quick Note"; macOS desktop widgets.
- [ ] Control Center "New Task" `ControlWidget`; macOS `MenuBarExtra` + registered global hotkey → quick-capture into a Markdown inbox note.
- [ ] Handoff/state restoration via `NSUserActivity`; `[[wikilink]]` autocomplete, nested tags, backlinks panel (linked vs unlinked), lightweight graph view, section deep-links, template files with frontmatter placeholders.
- [ ] (Optional) Apple Watch complication: today's open-todo count.
**Done:** "Hey Siri, add a task to Notetaker" works; a Lock Screen widget checks off a task; the global hotkey captures a note; Spotlight surfaces notes semantically.
**Effort:** ~2.5 weeks.

### M10 — Release / distribution
**Goal:** macOS signed+notarized+stapled `.dmg`; iOS on TestFlight.
**Steps:**
- [ ] **macOS:** Developer ID Application signing of the `.app` (+ embedded XPC helper/extensions) with Hardened Runtime; `codesign --deep` verification.
- [ ] `scripts/build-dmg.sh` using `create-dmg` (or `hdiutil`) to produce a styled `.dmg` with the app + Applications-folder alias.
- [ ] Notarize the `.dmg` via `notarytool submit --wait`; `xcrun stapler staple` the ticket; verify with `spctl -a -vvv` and Gatekeeper on a clean machine.
- [ ] **CI notes:** GitHub Actions macOS runner job (manual/tag-triggered) storing the Developer ID cert + notarization API key in encrypted secrets; artifacts = stapled `.dmg` + dSYMs; never commit secrets.
- [ ] **iOS:** archive → upload to App Store Connect → TestFlight internal testing; enroll Small Business Program (free PCC + fee tier); prepare App Store metadata + privacy nutrition labels (disclose iCloud storage + AI tiers honestly).
- [ ] Versioning/changelog; crash reporting (MetricKit).
**Done:** a downloaded `.dmg` opens without Gatekeeper warnings and drag-installs on a machine that never saw the source; `spctl` and `stapler validate` pass; a TestFlight build installs on a device.
**Effort:** ~1.5 weeks (first time; scripted thereafter).

---

## Sequencing & effort summary

| Milestone | Focus | Rough effort |
|---|---|---|
| M0 | Repo bootstrap + skeleton | 2–3 days |
| **M1** | **iCloud storage + sync (de-risk first)** | **~2 weeks** |
| M2 | Live-preview Liquid Glass editor | 2.5–3 weeks |
| M3 | Inline todos + index + master list | ~3 weeks |
| M4 | Recurrence, dates, filters, views | ~3 weeks |
| M5 | Import/conversion (File-Parser reuse) | ~3 weeks |
| M6 | AI provider abstraction | ~3 weeks |
| M7 | PM/Gantt (7a read-only → 7b interactive) | 1.5 + 3–4 weeks |
| M8 | Security hardening | 1.5–2 weeks |
| M9 | App Intents, widgets, surfaces | ~2.5 weeks |
| M10 | Signed/notarized `.dmg` + TestFlight | ~1.5 weeks |

**MVP (v0.1) cut line:** M0–M3 + the FMF/None slice of M6 + M5's native+inbox tiers + M10 — proves the thesis (portable `.md` + native editor + live master todo + iCloud + basic AI + distributable). M4, full M6, M7, M8 polish, M9 constitute v1.0.

**Invariant to protect through every milestone:** the `.md` files in iCloud are the single source of truth; the GRDB index is a disposable, always-rebuildable cache. Any bug that can't be fixed cleanly degrades to "drop the index and re-scan the vault" — never to data loss.

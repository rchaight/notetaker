# Notetaker — Feature Outline (FEATURES.md)

> Native macOS 27 + iOS 27 universal SwiftUI app. Markdown-first notes stored as real `.md` files in iCloud, with an inline-todo → master-task engine and a project/Gantt layer on top. This document drives the implementation plan.

---

## 1. Competitive landscape

The market splits cleanly: apps with **real portable `.md` files** are non-native (Electron) with painful DIY sync, while apps that **feel native with flawless iCloud sync** lock notes in proprietary stores. **No one combines both, and no one adds a real PM/Gantt layer on top of inline-note todos.** That gap is Notetaker's thesis.

| Product | Category | Storage / Sync | What Notetaker takes | What to avoid |
|---|---|---|---|---|
| **Obsidian** | PKM / md | Plain `.md` vault; DIY or paid Sync | Plain-`.md`-on-disk as source of truth; Live Preview hybrid editing; backlinks panel; lightweight graph; nested tags | Electron non-native feel; iCloud-folder conflict files; plugin-instability; sync as paid add-on |
| **Logseq** | Outliner / md | Plain md/org; sync stuck in beta for years | Outliner quick-capture mode; daily-journal landing; SCHEDULED-vs-DEADLINE dates; state-cycling | *Cautionary:* never leave sync/storage architecture in beta while charging; overdue tasks silently vanishing |
| **Bear** | Native md-ish | Proprietary DB (not `.md`); iCloud paywalled | Native Apple typography/polish bar; nested tags as folder alternative; linked + unlinked mentions; search inside images/PDFs | Proprietary format (no real `.md`); sync fully paywalled |
| **Craft** | Native blocks | Proprietary JSON; iCloud | Sub-second sync feel as perf bar; Shortcuts/Writing Tools/widget integration; clean default styling | Proprietary block store; not portable text |
| **iA Writer** | Native md | True `.md` on disk; iCloud transport | Validates `.md` + iCloud transport; Focus Mode; AI-authorship provenance marking; fast library search | No backlinks/tags/PM — too minimal |
| **Ulysses** | Native md-ish | Library DB; mature iCloud | Sheets/groups/smart-filters metaphor; writing goals/stats; iCloud reliability bar; direct-publish export | Subscription-only; not `.md` on disk |
| **Apple Notes** | Native | Proprietary iCloud store | Smart Folders (tag-rule saved views) → model for master To-Do; invisible-sync reliability bar; section deep-links; Siri hooks | No `.md`; no backlinks/graph; weak for large KBs/PM |
| **Zettlr** | Academic md | Plain CommonMark/Pandoc md; no sync | Citation/Zotero integration; Pandoc-grade export; inline Mermaid; project export templates | Electron; no mobile; no sync |
| **Todoist** | Tasks | Proprietary cloud | **NL Quick Add parsing** (date/recurrence/priority in one line); P1–P4 priorities; free-form Labels; saved-filter query language; Sections; optional streaks | Proprietary cloud; 5-project free cap; not `.md` |
| **Things 3** | Tasks | Proprietary Things Cloud | Areas>Projects>Tasks model; start-date vs deadline; "This Evening"; in-task checklists; global Quick Entry hotkey; calm native design bar | Proprietary sync; no custom filters; no PM |
| **OmniFocus 4** | Tasks (power) | iCloud or Omni server | Custom Perspectives (UI-built saved views); Defer/Planned/Due 3-date model; sequential-vs-parallel projects; Focus mode; interactive-widget completion | Steep learning curve; complexity/cost |
| **TickTick** | Tasks | Proprietary cloud | Pomodoro module; habit tracker; Eisenhower Matrix view; multi-view over one dataset | Cluttered; not native; proprietary |
| **Apple Reminders** | Tasks | **Native iCloud/CloudKit** | Reference impl for CloudKit task sync + conflict handling; Tags+Smart Lists; Siri/Visual Intelligence/Shortcuts; Shared Lists | Flat lists; no projects/PM; not `.md` |
| **Notion / Anytype / Capacities / Tana / Coda / AppFlowy** | All-in-one | Proprietary (cloud or object DB) | **Multi-view over one record** (table/board/calendar/timeline); Relations+Rollups; Supertags→inline-typed-todos; per-type templates; AI action-item extraction; local-first ethos | Proprietary/cloud stores; Electron; not `.md`; disqualifying for hard iCloud+file req |
| **NotePlan** | Hybrid note+task | **Plain `.md` + CloudKit** | *Closest architectural precedent:* `>date` inline scheduling; reference-based live aggregation (one task, many views); CloudKit sync of `.md` | No PM/Gantt; subscription-only; sync-toggle rough edges |
| **Amplenote** | Hybrid note+task | Proprietary cloud | `[] ` inline task shorthand; computed **Task Score** for auto-sort; "jump to note"; in-note Completed section | Proprietary cloud; not iCloud/`.md` |
| **Obsidian Tasks + Dataview** | Hybrid plugins | Plain `.md` | Plain-text-appended metadata; live query-block master list; "when done" vs fixed recurrence | *Pitfall:* Dataview marks recurring done but never regenerates next instance — never split check-off from recurrence logic |
| **Capacities** | Hybrid | Proprietary cloud | **Zero-config Inbox/Today/Scheduled defaults**; auto per-project Tasks tab; sub-checkbox progress ring | Proprietary; lossy md export |
| **OmniPlan / Merlin Project** | Native PM/Gantt | iCloud Drive | Native iCloud-Drive sync validation; auto critical-path; baseline "slipped N days"; one task record → Gantt/Kanban/Mindmap views | Enterprise density; intimidating for personal use |
| **Asana / Monday / ClickUp / TeamGantt / MS Project / Linear / Notion Timeline** | SaaS PM/Gantt | Proprietary cloud | Drag-to-reschedule + auto-cascade; draw-a-line dependencies; diamond milestones; **ungated critical path + slack** (ClickUp); day/week/month zoom; **auto % from child completion** (Linear); **Gantt is just another view** (Notion) | Per-seat SaaS; critical-path paywalls; enterprise bloat (resource leveling, EVM, portfolios) |

---

## 2. Core design decisions

Opinionated calls that anchor the build. Each is a hard commitment, not an option.

1. **Plain `.md` files are the single source of truth.** Real CommonMark/GFM files in a Finder/Files-visible iCloud Drive folder — never a proprietary DB. *Rationale: no researched "native" app (Bear/Craft/Ulysses/Apple Notes) offers real `.md`; combining portability with native polish is the market gap.*
2. **iCloud Drive Documents (ubiquitous container), not CloudKit records, for notes.** With rigorous `NSFileCoordinator`/`NSFilePresenter` (via `UIDocument`/`NSDocument`). *Rationale: CloudKit can't produce human-readable files openable in Windows/Obsidian/a text editor; plain-file portability is the differentiator. Use CloudKit only for lightweight index/metadata if needed.*
3. **Ship complete, reliable sync + a stable file format at v1 — no "coming later" architecture.** *Rationale: Logseq's multi-year unfinished storage migration and years-in-beta sync destroyed user trust.*
4. **Live Preview hybrid editing is the default.** Hide raw markdown syntax except on the line at the cursor; real `.md` underneath; optional Source and Focus modes. *Rationale: the modern default between pure source (iA/Zettlr) and pure WYSIWYG (Craft/Notes).*
5. **Liquid Glass console.** The editor UI uses Apple's Liquid Glass materials (macOS 26+/iOS 26+) for a polished, native-feeling surface. *Rationale: hard requirement; native polish is the whole positioning vs Electron incumbents.*
6. **Inline todos in plain-text CommonMark, parsed into an in-memory index.** Syntax: `- [ ] Task text >2026-07-15 !high #project` — GFM checkbox + NotePlan-style `>date` (with `>today`/`>tomorrow`/`>friday` NL shortcuts) + `!priority` + existing `#tag`. *Rationale: keeps files portable/diffable (avoids Obsidian Tasks' emoji noise) while still queryable in-app.*
7. **The master To-Do tab is a LIVE bidirectional view over the same `.md` lines — never a copy.** Checking a box anywhere (master list, Today, project Kanban, in-note) edits the exact source line, and vice versa. *Rationale: NotePlan/Amplenote/Obsidian-Tasks prove reference-based aggregation is correct; copied task DBs drift.*
8. **One recurrence engine, invoked identically from every surface.** *Rationale: Dataview's footgun — an aggregated view that marks done but never regenerates the next instance — must be structurally impossible.*
9. **Overdue todos never silently disappear.** Undone past-due items roll into an Overdue bucket until completed, rescheduled, or dismissed. *Rationale: top user complaint against Logseq's journal model.*
10. **Two date concepts minimum: `>due` and optional `>start`/scheduled.** *Rationale: Logseq SCHEDULED-vs-DEADLINE and Things start-vs-deadline both prove users conflate these; needed for clean Today/Upcoming.*
11. **The PM/Gantt layer is another view over the same todos + frontmatter, not a second data model.** Project = a note with frontmatter; its tasks are the inline todos that reference it. *Rationale: universal convergence across Notion/Asana/OmniPlan — Gantt items ARE the aggregated tasks.*
12. **Zero-config smart views ship pre-built (Inbox / Today / Upcoming / By Project), with power-user saved filters on top.** *Rationale: Capacities' pre-built dashboard beats Obsidian's manual-query onboarding; progressive disclosure keeps power without complexity.*
13. **Reuse File-Parser/Docling for import; prefer native Apple engines where they win.** Vision `RecognizeDocumentsRequest` for images/scans/PDF, `SpeechAnalyzer`/`SpeechTranscriber` for audio, Docling for complex DOCX/PPTX. *Rationale: native paths are faster/on-device; Docling covers the hard cases without rebuilding OCR/transcription.*
14. **AI is private/on-device by default via an `AIProvider` protocol.** `FoundationModelsProvider` (Apple Intelligence) + `OllamaProvider` (homelab) + `NoneProvider` (regex/NSDataDetector fallback), gated on `SystemLanguageModel.default.availability`. *Rationale: WWDC26 abstraction; 4096-token on-device limit forces routing long inputs to Ollama/PCC; app must stay fully usable offline and on ineligible hardware.*
15. **One `AppIntent` family ("Add Task"/"Create Note") is built first.** It feeds Siri, Spotlight, Shortcuts, Control Center, and interactive widgets simultaneously. *Rationale: highest ROI integration; build on App Intents 2.0 (SiriKit deprecated at WWDC26).*
16. **macOS ships as a Developer ID-signed, notarized `.app` in a `.dmg`; iOS via TestFlight/App Store.** *Rationale: hard distribution requirement.*
17. **Single-user, local-first. No collaboration, no plugin marketplace in the roadmap.** *Rationale: solo developer sustainability; plugin ecosystems bring instability/security burden; collaboration is a separate product bet.*

---

## 3. Feature outline

Tiered MVP (v0.1) → v1.0 → v2.0+. Each feature is one line.

### MVP — v0.1 (prove the thesis: portable `.md` + native editor + live master todo + iCloud)

**Notes / editor**
- Liquid Glass editing console with polished native macOS/iOS chrome.
- Live Preview hybrid editor over real `.md`: hide markdown syntax except at the cursor line.
- Full CommonMark/GFM live formatting as you type (headings, bold/italic, lists, tables, code fences w/ syntax highlighting, task checkboxes, blockquotes, links).
- Source mode toggle and Focus Mode (fade all but current sentence/paragraph).
- Built on TextKit 2 (`NSTextView`/`UITextView`) so Apple Writing Tools work in every note for free.

**Linking / organization**
- Folder tree mirroring the on-disk iCloud vault structure (Finder/Files-visible).
- `[[wiki-links]]` with autocomplete.
- Nested tags (`#work/project`) as a folder-alternative hierarchy.
- Fast library-wide full-text search across all notes.

**Import / conversion**
- Share Extension: send text/URL/file into a new or existing note.
- Import PDF/DOCX/PPTX/image/audio → Markdown by routing non-text payloads through the File-Parser/Docling engine (native Vision/Speech paths where they win).

**Todos**
- Inline todo syntax `- [ ] text >due !priority #tag` authored in any note.
- Background parser/indexer builds a live in-memory todo index from `.md` files.
- Master To-Do tab as a live bidirectional view: check off anywhere → edits source line.
- Pre-built smart views: Inbox (undated), Today (due + overdue), Upcoming.
- Overdue bucket so nothing past-due silently vanishes.
- P1–P4 priorities and `>date` with `>today`/`>tomorrow`/`>friday` NL shortcuts.

**Sync / storage**
- iCloud Drive Documents container with correct `NSFileCoordinator`/`NSFilePresenter` (`UIDocument`/`NSDocument`).
- `*conflicted copy*.md` detection banner with a simple resolve UI.

**Platform surfaces**
- Universal SwiftUI target: `NavigationSplitView` (sidebar → note list → editor), adaptive iPhone/iPad/Mac.
- macOS menu bar (`CommandGroup` File/Edit/View) for keyboard-driven power users.
- One `AppIntent` family (Add Task / Create Note) → Siri + Spotlight + Shortcuts.

**AI (baseline)**
- `AIProvider` protocol + `FoundationModelsProvider` + `NoneProvider` fallback, gated on availability.
- NL task parsing (date/priority/tags from typed text) via Foundation Models `@Generable` guided generation, with `NSDataDetector` regex fallback.

**Distribution**
- macOS `.dmg`, Developer ID signed + notarized; iOS TestFlight build.

### v1.0 (the differentiated product: full todos + PM/Gantt + AI + surfaces)

**Notes / editor**
- Backlinks panel distinguishing linked vs unlinked mentions (Bear-style).
- Lightweight graph view of note connections.
- Section deep-links (link to a heading within a long note).
- Markdown template files with frontmatter placeholders that auto-populate on note creation (meeting notes, project briefs, weekly review).
- Outliner / block quick-capture mode and a daily-journal landing view (optional).
- Ulysses-style smart-filter saved views over notes; writing goals/stats.

**Todos (Todoist-grade)**
- NL Quick Add parser as the standard entry path everywhere (one line → date/recurrence/priority/project/labels).
- Free-form Labels as a cross-cutting axis separate from folders/tags.
- Saved custom Filters (query syntax e.g. `priority:P1 AND due:today`) plus a visual Perspective-style builder.
- Two recurrence modes: fixed-schedule and completion-based ("every 7 days when done"), via one shared engine on all surfaces.
- Start/scheduled vs due date distinction (optionally a third Planned date, OmniFocus-style).
- In-task checklists / nested sub-checkboxes with a progress ring.
- Computed relevance/Task Score for auto-sorting undated todos (Amplenote-style).
- "Jump to note" from any master-list row; in-note Completed section.
- Additional built-in views: Kanban board, Calendar, Eisenhower Matrix — all over the one todo dataset.
- EventKit two-way integration: attach a native Reminder/alert to a todo; NL date at creation.

**Project management / Gantt**
- Projects as notes with frontmatter (`status`, `start`, `due`, `project` relations).
- Gantt/Timeline as another view over aggregated todos: drag-resize/reschedule bars, day/week/month zoom.
- Finish-to-start dependencies via direct draw-a-line-between-bars gesture, with auto-cascade + downstream-impact indicator.
- Milestones as zero-duration diamond markers.
- Auto-computed % complete from checked-off child todos (Linear-style, no manual entry).
- Ungated automatic critical-path highlight + slack/float per task (ClickUp-style, never paywalled).
- Lightweight roadmap timeline default for new/small projects; "graduate" to full Gantt when needed.
- Alternate Kanban and canvas/board view per project.

**Sync / storage**
- Sync-reliability hardening to the Apple Notes/Reminders invisibility + Craft sub-second bar.

**AI (Apple Intelligence + Ollama)**
- `OllamaProvider` with prefilled `http://<homelab-ip>:11434`, optional Bonjour discovery, `/api/tags` health check + model picker + Test Connection; persist URL only.
- Note summarization and action-item extraction into inline `- [ ]` todos (route long notes to Ollama/Private Cloud Compute; short to on-device).
- Semantic vault search via `NLContextualEmbedding` + local vector store (VecturaKit), chunked to embedding limits; notes/todos exposed as `IndexedEntity` for system semantic search.
- Audio/meeting import: `SpeechAnalyzer`/`SpeechTranscriber` transcription → LLM cleanup pass on Ollama/PCC.
- AI-authorship provenance marking (flag AI-pasted vs human-written text), iA Writer-style.

**Security**
- App lock (Face ID / Touch ID / passcode) on launch and on resume.
- Per-note locked/encrypted notes (Bear-style).

**Platform surfaces**
- Home/Lock Screen interactive widgets: "Today's Tasks" (check off inline via `AppIntent`) and "Quick Note" (tap-to-capture); macOS desktop widgets.
- Control Center "New Task" control (`ControlWidget`) → iPhone, Lock Screen, Action Button.
- macOS `MenuBarExtra` + registered global hotkey for quick capture into a Markdown inbox note.
- Handoff / state restoration via `NSUserActivity` (open note + cursor position); Universal Clipboard (free).
- Apple Watch complication showing today's open-todo count (differentiates from NotePlan; cheaper than a full watch app).

### v2.0+ (depth, power users, ecosystem polish)

**Notes / editor**
- Zettelkasten ID-based linking mode for research notes.
- Citation / Zotero / BibTeX reference-manager integration.
- Inline Mermaid diagram rendering; LaTeX math.
- PencilKit ink layers + Apple Pencil handwriting → OCR-to-Markdown (iPad).
- Canvas/whiteboard mode.

**Todos / PM**
- OmniFocus-grade Custom Perspectives as a full visual view builder.
- Sequential-vs-parallel project semantics for richer dependency ordering.
- Baseline snapshots ("this task slipped N days") and click-a-task-to-highlight-predecessor/successor-chain.
- Optional advanced dependency types (SS/FF/SF) behind a progressive-disclosure toggle.
- Optional toggleable gamification (streaks/Karma); Pomodoro/focus-timer module tied to todos; habit tracker.
- Focus mode scoping the whole app to one folder/project subtree.

**AI**
- Project-plan / Gantt drafting from a prose brief via Ollama.
- Larger-model Ollama routing (Gemma3-12B / Qwen3-8/14B; tool-calling-strong granite4/qwen3 for structured extraction).

**Platform surfaces**
- Live Activity for an opt-in focused-task/session timer (auto-relays to Watch Smart Stack; keep short-lived given user backlash).
- Full native watchOS app (only if post-launch usage justifies it).
- iOS 27 Visual Intelligence capture (photograph a flyer → auto-fill a todo/note).
- Direct-publish export integrations (WordPress/Medium/Ghost) and Pandoc-grade multi-format export with project export templates.

---

## 4. Explicitly out of scope

Deliberate non-goals. Each protects focus, sustainability, or the core architecture.

- **Real-time multi-user collaboration / shared notes / live cursors / comments.** *Notetaker is single-user local-first; collaboration is a separate product bet, adds a sync/permissions/CloudKit-sharing surface a solo dev can't sustain at v1, and conflicts with the plain-`.md`-file model.*
- **Third-party plugin API / marketplace.** *Obsidian's 5,000+ plugins drive retention but bring UI inconsistency, instability, and security/maintenance risk; a curated first-party feature set (queries, Kanban, canvas, Gantt) is more sustainable. Revisit only after the core is rock-solid.*
- **Non-Apple native apps (Windows/Android/web clients).** *The portable `.md`-in-iCloud model already gives cross-OS read/edit access via iCloud.com, iCloud for Windows, and any text editor. Native polish on Apple platforms is the entire positioning — going cross-platform would force the Electron compromise being differentiated against.*
- **CloudKit-record storage for notes / a proprietary database.** *Directly violates the plain-portable-`.md` hard requirement; the whole differentiator is files openable outside the app.*
- **Bundling a second sync engine or supporting a second sync client on the same folder.** *iCloud + a second sync tool (Obsidian Sync, Dropbox) on one folder is a documented, reproducible cause of `(conflicted copy)` duplication. Document it as unsupported; detect and warn rather than support.*
- **Enterprise PM machinery: resource pools/leveling, budget/cost tracking, EVM, portfolio rollups, AI schedule-risk agents.** *Consistently cited as enterprise-only bloat (MS Project/OmniPlan territory) personal users never reach for; would bury the app under complexity.*
- **Dedicated visionOS spatial UI.** *No meaningful spatial note-taking adoption data ~2 years post-launch. The universal iPad app runs on visionOS 26 for free and widgets auto-propagate — accept the halo effect, defer native spatial work until demand signals appear.*
- **A separate manually-maintained task list decoupled from note content.** *The master To-Do tab must always be a live index over inline `.md` todos; a parallel task DB that can drift is an anti-pattern the whole architecture rejects.*

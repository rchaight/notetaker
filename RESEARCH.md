# Notetaker — competitive & technical research

> Compiled 2026-07-10 by a 12-agent research workflow (6 sonnet product/device researchers, 4 opus technical researchers, opus synthesis & planning). See FEATURES.md for the distilled feature outline and PLAN.md for the implementation plan.

## Markdown-first note apps

### Obsidian

- **Platforms:** macOS, Windows, Linux, iOS, Android (Electron/Capacitor-based, not native Apple frameworks)
- **Pricing:** Free core app (no feature restrictions). Optional add-ons: Sync $5/mo ($4/mo billed annually), Publish $10/mo, optional commercial license $50/user/year.
- **Storage & sync:** Notes stored as plain .md files directly in a local folder ('vault') on disk — no proprietary database. No forced sync layer: users can sync the vault folder themselves via iCloud Drive/Dropbox/Syncthing/Git, or pay for first-party Obsidian Sync.

**Key features**

- Live Preview hybrid editing mode (raw markdown hidden except near cursor) plus a true Source mode and rendered Preview
- Bidirectional [[wiki-links]] with automatic Backlinks panel
- Graph view visualizing note connections across the vault
- Nested/hierarchical tags and powerful full-text + regex search
- Massive community plugin ecosystem: 5,000+ plugins and 580+ themes (Dataview, Excalidraw, Kanban, Canvas, task managers, AI assistants)
- Daily notes, templates, canvas whiteboards

**Strengths**

- Plain-text, local-first files mean zero lock-in and full interoperability with any other markdown tool
- Free core with no forced subscription; works fully offline
- Extremely extensible via plugins, active large community
- Graph view and backlinks make relationship-mapping across notes tangible

**Weaknesses**

- Sync is either a paid add-on or a DIY folder-sync setup with real conflict risk
- Electron-based UI does not feel like a native Apple app (no native widgets, less polished animations/typography)
- Plugin ecosystem can introduce instability, inconsistent UX, and security risk
- Steeper learning curve than native note apps; mobile experience is clunkier than Bear/Craft/Apple Notes

**Worth adopting in Notetaker**

- Storing notes as literal plain .md files in a visible folder structure (no proprietary DB) — the core of Notetaker's hard requirement
- Live Preview hybrid editing style (hide syntax near cursor, show it when editing that line) as the default editor UX
- Backlinks panel + lightweight graph view for note relationships
- Nested tags for lightweight hierarchical organization
- Layering paid/advanced features (sync, publish) on top of a fully free, fully functional core — though for Notetaker, iCloud sync itself is the hard requirement, not an upsell

### Logseq

- **Platforms:** macOS, Windows, Linux, iOS, Android (Electron-based)
- **Pricing:** Free tier with core features. Logseq Sync still in beta as of 2026, offered via Open Collective donation tiers ($5/mo Backers, $15/mo Sponsors) rather than a finalized commercial price.
- **Storage & sync:** Notes stored as plain markdown or org-mode files locally. No mature first-party sync (official Sync/RTC has been in beta for years); users commonly self-sync via iCloud, Dropbox, Git, or Syncthing. Team has been mid-migration from file-based to a database-backed core since 2022, still unfinished in 2026.

**Key features**

- Block-based outliner as the fundamental note structure (not freeform documents)
- Bidirectional links and graph view
- Journal/daily-notes as the default landing view
- Tasks and spaced-repetition flashcards embedded as blocks
- Whiteboards, Datalog-style advanced queries, PDF annotation, Zotero integration
- Plugin ecosystem (GitHub integration, flashcards, themes)

**Strengths**

- Free and open, plain-text file storage (markdown or org)
- Outliner model is fast for atomic note capture and linking
- Flexible structured query system beyond simple search
- Active plugin community

**Weaknesses**

- Years-long, still-incomplete migration to a database-based core architecture has consumed most development bandwidth
- Official Sync/real-time-collaboration has been stuck in beta for years while still collecting paid donations — users feel they're paying for unfinished infrastructure
- Graph and app performance degrade once a vault crosses a few thousand notes
- Mobile sync reliability issues and reduced mobile functionality versus desktop
- UI less polished/native than Apple-first apps

**Worth adopting in Notetaker**

- Outliner-first, block-based quick-capture model as an alternative editing mode for fast note-taking
- Daily journal as a default/optional landing view
- Tasks and flashcards represented as first-class queryable blocks inside notes, aggregable via structured queries — directly relevant to the master To-Do tab
- Cautionary lesson: never leave core sync/storage architecture in beta for years while charging or promising it — ship reliable iCloud sync and a stable file format from v1

### Bear

- **Platforms:** macOS, iOS, iPadOS only (no Windows/Android)
- **Pricing:** Bear Pro $2.99/mo or $29.99/yr, 14-day free trial. Free tier is single-device only with no sync, no export, no themes, no encryption.
- **Storage & sync:** Notes stored in Bear's own internal database (not user-accessible plain .md files); markdown-compatible editing but true interop requires export. iCloud sync is seamless but fully gated behind the paid Pro tier.

**Key features**

- Nested tags (slash-delimited, e.g. books/harry-potter) that act as an automatic hierarchical table of contents
- Wiki-style [[links]] with a Backlinks panel distinguishing 'linked mentions' from 'unlinked mentions'
- Fast cross-note search, including text search inside embedded photos and PDFs
- Code blocks with syntax highlighting for 150+ languages, LaTeX math
- Export to PDF, HTML, DOCX, JPG; note-level encryption/locking; polished themes

**Strengths**

- Beautiful, genuinely native Mac/iPhone/iPad design, typography, and performance
- iCloud sync is smooth and effectively invisible once subscribed
- Nested tags provide folder-like organization without manual folder management
- Backlinks with unlinked-mention detection is a thoughtful linking feature
- Simple, low-cost single-tier pricing

**Weaknesses**

- Notes are NOT stored as plain .md files on disk — proprietary internal format, must export for portability
- No graph view or deeper knowledge-graph visualization
- Sync entirely paywalled; free tier essentially unusable across devices
- Apple-only, no plugin/extension ecosystem, minimal task/PM capability

**Worth adopting in Notetaker**

- Nested tags as an intuitive folder alternative
- Wiki-link + Backlinks panel that surfaces both linked and unlinked mentions of a note title
- The native, fast, beautifully typeset Apple-first editing feel and theming — a UX bar to match
- Search that spans note text plus embedded image/PDF content (relevant to File-Parser OCR imports)

### Craft

- **Platforms:** macOS, iOS, iPadOS, Windows, Android, Web
- **Pricing:** Free plan (unlimited docs, basic collaboration, offline). Plus ~$4.80/mo billed yearly, Family ~$9/mo billed yearly, Team $60/mo (up to 10 members).
- **Storage & sync:** Proprietary JSON-based block storage internally, not plain markdown on disk. iCloud sync supported on Apple platforms; also has its own cross-platform sync for non-Apple devices. Markdown/TextBundle export available but native storage is not user-editable plain text.

**Key features**

- Block-based rich document editor with real-time multi-user collaboration, comments, and access controls
- iCloud sync plus Shortcuts, Apple Writing Tools, and Lock Screen widget integration
- Daily notes, cross-document linking, AI-assisted writing
- Sub-second page loads and near-instant sync
- Export to Markdown, TextBundle, PDF, Word

**Strengths**

- Gorgeous, native-feeling Apple design that also reaches non-Apple platforms
- Strong, smooth real-time multi-user collaboration for small teams
- Fast, responsive block editor with reliable instant sync
- Deep native Apple platform integrations (Shortcuts, Writing Tools, widgets)

**Weaknesses**

- Internal storage is proprietary JSON blocks, not plain markdown files — real portability requires exporting
- Pricing scales up notably for Family/Team tiers
- Less suited to backlink-heavy PKM/graph workflows than Obsidian/Logseq/Zettlr
- Small plugin/extensibility ecosystem compared to Obsidian

**Worth adopting in Notetaker**

- Real-time multi-device and multi-user collaboration UX (live cursors, comments, access controls)
- Native Apple integrations: Shortcuts actions, Writing Tools, Lock Screen widgets
- Clean, presentation-ready default document styling out of the box
- Sub-second sync feel as a performance bar for CloudKit-based sync

### iA Writer

- **Platforms:** macOS, iOS, iPadOS, Windows
- **Pricing:** One-time purchase, no subscription: $49.99 Mac, $49.99 iPhone & iPad, $29.99 Windows.
- **Storage & sync:** True plain .md files stored directly on the filesystem; syncs via iCloud (or Dropbox), so files remain fully portable and editable in any text editor.

**Key features**

- Focus Mode that highlights only the current sentence/paragraph and fades the rest
- Markdown syntax highlighting and a built-in style/syntax checker
- Authorship tracking (2026 addition) that visually flags AI-pasted vs human-written text
- Library-wide fast search and filtering across all markdown files
- Templates and multi-format export

**Strengths**

- Genuine plain-text files with zero lock-in — files live on disk, sync is just a transport
- No subscription; one-time purchase model
- Minimalist, distraction-free writing UX with fast native performance
- Forward-looking AI-provenance (Authorship) feature addresses a real 2026 writing concern

**Weaknesses**

- No backlinks, graph view, or tagging system — not built for PKM/knowledge-linking
- Minimal project/task management capability
- Library model is less suited to large interconnected note collections
- Not designed for team collaboration

**Worth adopting in Notetaker**

- Plain .md-on-disk with iCloud as the sync transport — directly validates Notetaker's storage/sync hard requirement
- Focus Mode for distraction-free drafting
- Authorship/AI-text-provenance marking, increasingly relevant as AI-assisted writing grows
- Fast library-wide search across the whole markdown collection

### Ulysses

- **Platforms:** macOS, iOS, iPadOS only (explicitly no Windows/Android plans)
- **Pricing:** Subscription only: $5.99/mo or $49.99/yr, covers Mac+iPhone+iPad, includes Apple Family Sharing (up to 6 members). No lifetime option.
- **Storage & sync:** Sheets organized in an internal library/database structure rather than exposed as raw .md files by default, though markdown ('Markdown XL') is the underlying syntax and export to plain files is supported. iCloud sync across Mac/iPad/iPhone is mature and reliable.

**Key features**

- Library organized into sheets, groups, and smart filters (saved-search-like views)
- Extended 'Markdown XL' syntax
- Writing goals and statistics tracking
- Direct publishing integrations: WordPress, Medium, Ghost, Micro.blog
- Export to PDF, DOCX, HTML, ePub

**Strengths**

- Very reliable, fast, mature native iCloud sync across all Apple devices
- Sheets/groups/filters give a powerful alternative to simple folders for managing many documents
- Polished, native Apple UX; Family Sharing included in subscription
- Strong long-form writing and direct-publishing workflow

**Weaknesses**

- Subscription-only, no one-time purchase
- No backlinks or graph view — not a PKM/linking tool
- Apple-only, limited task/PM features
- Documents not exposed as plain .md files on disk by default

**Worth adopting in Notetaker**

- Library sheets/groups/smart-filters as an organizational metaphor complementary to folders
- Writing goals/stats as an engagement feature
- Its native iCloud sync reliability as the engineering bar for Notetaker's own CloudKit-based sync
- Built-in direct publishing integrations as a model for export/sharing features

### Apple Notes

- **Platforms:** macOS, iOS, iPadOS, visionOS, iCloud.com (fully native, built into the OS)
- **Pricing:** Free, bundled with Apple devices and iCloud.
- **Storage & sync:** Notes stored in Apple's proprietary iCloud-backed store (not user-accessible plain .md files). iCloud sync is automatic, invisible, and highly reliable across all of a user's Apple devices.

**Key features**

- Tags with a dedicated Tags browsing section, and Smart Folders that auto-update based on tag rules
- Real-time multi-user collaboration with live cursors and inline comments
- Advanced linking, including deep-links to specific sections within long notes (new in iOS/macOS 27)
- Markdown copy-and-paste support (new in iOS 27) improving interop with other markdown apps
- Siri voice control for creating/finding/editing notes; document scanning and OCR; checklists; handwriting

**Strengths**

- Zero cost, deeply native, and iCloud sync is essentially flawless and invisible
- Smart Folders auto-organize notes by tag rules without manual upkeep
- Strong built-in real-time collaboration (comments, live cursors)
- Now finally gaining markdown interoperability and precise section-level linking

**Weaknesses**

- Notes are not stored as user-accessible plain .md files — no true markdown-file portability
- No true backlinks/graph view for knowledge-graph style relationship mapping
- No plugin ecosystem or deep customization
- Weak for large structured knowledge bases, advanced search/query, or project-management/Gantt-style work

**Worth adopting in Notetaker**

- Smart Folders (dynamic, tag-rule-based saved views) as the direct model for Notetaker's master To-Do tab and other aggregated views
- Apple's invisible, rock-solid iCloud sync as the reliability bar for CloudKit implementation
- Deep-linking to a specific section within a note
- Native real-time multi-user collaboration (live cursors, comments)
- Siri/Shortcuts integration hooks

### Zettlr

- **Platforms:** macOS, Windows, Linux (Electron-based; desktop-only, no official mobile app)
- **Pricing:** Completely free and open source, donation-supported, no premium tiers.
- **Storage & sync:** Notes stored as plain CommonMark/GFM/Pandoc-flavored markdown files on disk. No built-in sync service — relies entirely on external file sync (iCloud Drive, Dropbox, Git, etc.).

**Key features**

- Zettelkasten-style note IDs with internal wiki-links and a graph view of connections
- Tags, footnotes, LaTeX math, Mermaid diagram rendering
- Citation and reference-manager integration (Zotero, BibTeX)
- Pandoc-powered export to PDF, Word, HTML and more, with project-based export and custom templates
- Multi-cursor editing, Vim/Emacs modes, spell/grammar check (LanguageTool), built-in Pomodoro timer

**Strengths**

- Fully free, open source, plain markdown files with no lock-in
- Strong academic/research writing toolset (citations, LaTeX, Pandoc export fidelity)
- Cross-platform desktop support
- Graph view supports genuine Zettelkasten-style knowledge work

**Weaknesses**

- Not a native Apple app (Electron), so UI feels utilitarian rather than polished/native
- No built-in sync — entirely dependent on external tools for cross-device access
- No mobile app at all
- Smaller, slower-moving plugin ecosystem than Obsidian

**Worth adopting in Notetaker**

- Zettelkasten ID-based linking model as an option for research-oriented notes
- Citation/reference-manager integration for academic use cases
- Pandoc-grade export fidelity to many document formats
- Inline Mermaid diagram rendering
- Project-scoped export templates

### Cross-product takeaways

- Plain .md-on-disk storage (Obsidian, iA Writer, Zettlr, Logseq) is what truly delivers no-lock-in interoperability; none of the polished 'native Apple' apps (Bear, Craft, Ulysses, Apple Notes) actually store notes as user-accessible plain markdown files despite markdown-like editing or export — Notetaker should store real .md files in an iCloud Drive-visible folder structure to combine both worlds, which is a genuine market gap.
- Native iCloud sync is proven highly reliable when built directly on Apple's frameworks (Apple Notes, Bear, Craft, Ulysses, iA Writer); by contrast Obsidian and Logseq's non-native approaches (DIY folder sync or a bolted-on paid Sync/RTC service stuck in beta for years) are well-documented pain points — building natively on CloudKit/iCloud Drive from day one directly targets a problem competitors struggle with.
- A good linking/tagging strategy emerges by combining patterns: wiki-links plus a Backlinks panel distinguishing linked vs unlinked mentions (Bear), an optional lightweight graph view (Obsidian/Logseq/Zettlr), nested tags for lightweight hierarchy (Bear), and tag-rule-based Smart Folders/saved dynamic views (Apple Notes) — the latter is a strong direct model for the master To-Do tab (e.g. a 'smart folder' that auto-aggregates all inline #todo items across notes).
- Live Preview hybrid editing (Obsidian: hide raw markdown syntax except near the cursor) is the modern default editing UX, sitting between pure source-mode (Zettlr, iA Writer) and pure WYSIWYG block editors (Craft, Apple Notes, Bear); Notetaker should default to Live-Preview-style editing over a real markdown file underneath, rather than either extreme.
- Large plugin ecosystems (Obsidian's 5,000+, Logseq's) drive power-user retention and extensibility but bring UI inconsistency, instability, and security/maintenance risk, and are hard for a solo developer to support; a curated, first-party feature set covering the most-used plugin categories (Dataview-like queries, Kanban, canvas/whiteboard) is likely more sustainable than opening a plugin API in v1.
- Logseq's cautionary tale is directly relevant: a multi-year, still-unfinished migration to a new storage architecture combined with a sync feature stuck in beta for years while still collecting payment badly eroded user trust — Notetaker should ship a complete, reliable iCloud sync and a stable file format from v1 rather than promising architectural changes later.
- None of the 8 researched apps combine inline note-embedded todos with a genuine project-management/Gantt layer — Craft/Notion-adjacent tools get closest with docs plus light collaboration, but a Todoist/Notion-inspired master To-Do tab that aggregates inline note todos, paired with a full PM layer (projects, Gantt charts, task tracking), is real differentiation white space.
- 'Feeling native' — smooth animations, refined typography, Shortcuts/Siri integration, Apple Writing Tools, Lock Screen widgets, Family Sharing — is what separates Bear/Craft/Ulysses/Apple Notes/iA Writer from the Electron-based Obsidian/Logseq/Zettlr; matching that native polish while retaining Obsidian's open plain-text file model is Notetaker's core positioning opportunity.
- Alternative organizational metaphors beyond plain folders are worth blending in: Ulysses' sheets/groups/smart-filters and Bear's nested tags both let users navigate large note collections without heavy manual folder maintenance, and can layer on top of a folder-based markdown vault.
- Search needs to span more than note text: Bear indexes text inside embedded photos/PDFs, Obsidian supports regex and tag-scoped search, iA Writer offers fast library-wide search — since Notetaker imports PDFs/DOCX/images/audio via the File-Parser/Docling pipeline, unified full-text search should cover converted/imported content alongside native notes.

## Dedicated task managers

### Todoist

- **Platforms:** iOS, iPadOS, macOS, watchOS, Android, Windows, Linux, web, browser extensions, email plugins
- **Pricing:** Free tier capped at 5 active projects, no reminders/attachments; Pro $5/mo billed annually ($60/yr, $7/mo month-to-month) unlocks 300 active projects, reminders, attachments, 25 collaborators/project, advanced filters, automatic backups, and AI features; Business $8/user/mo annual ($96/user/yr) adds team admin/roles. Prices raised Dec 2025.
- **Storage & sync:** Proprietary cloud (Doist servers), fully proprietary data format, not local files, no native iCloud option

**Key features**

- Quick Add with natural-language date/time/recurrence parsing (e.g. "Submit report every second Thursday at 3pm")
- Priorities P1-P4 (color-coded flags, P1 = urgent/red)
- Labels (free-form tags, cross-project, distinct from priorities and projects)
- Sections within projects for sub-grouping
- Saved/custom Filters using a query language (e.g. "p1 & today", "overdue | no due date") combining labels, priorities, dates, projects
- Karma gamification: points for completing tasks, streaks, daily/weekly goals, levels; can be toggled off
- Todoist Assist (AI task breakdown, smart scheduling, filter builder)
- Todoist Ramble - voice-to-task AI (launched Jan 2026, Gemini 2.5 Flash Live, 38 languages, 10 free sessions/mo)
- Email Assist - extracts action items from forwarded emails
- Recurring due dates with flexible natural-language recurrence rules
- Today/Upcoming board and list views, Kanban board view
- Collaboration: shared projects, assigned tasks, comments (up to 25 collaborators/project on Pro)
- Widgets on iOS/macOS/Android, Apple Watch app

**Strengths**

- Best-in-class natural-language quick-entry UX widely regarded as the genre benchmark
- Powerful, flexible saved-filter query language for custom views
- Mature cross-platform reach and integrations (Gmail, Slack, calendar apps, Zapier, etc.)
- Karma/streaks provide lightweight motivational gamification without being heavy-handed
- Sections give sub-project structure without full nested-project complexity

**Weaknesses**

- Free tier artificially capped at 5 projects, pushing most real users to paid
- Fully proprietary cloud storage - no iCloud, no local Markdown files, hard to own/export your data
- No native Markdown notes - pure task manager, not a notes app
- Karma/gamification and AI features add complexity some users don't want
- Subscription pricing rose again in Dec 2025, ongoing cost creep

**Worth adopting in Notetaker**

- Adopt the natural-language Quick Add parser as the standard for inline todo creation inside notes and in the master To-Do tab (dates, recurrence, priority all parsed from one line of typed text)
- Adopt P1-P4 priority levels as a simple, familiar priority scheme
- Adopt free-form labels (separate axis from folders/projects) for cross-cutting tags on todos
- Adopt a saved-filter/query system (e.g. "priority:P1 AND due:today") for the master To-Do tab so users can build custom smart views
- Adopt Sections as a lightweight sub-grouping inside a project/note before committing to full subprojects
- Consider optional, toggleable lightweight gamification (streaks) as a nice-to-have, not core

### Things 3

- **Platforms:** macOS, iOS, iPadOS, watchOS (no Windows/Android/web)
- **Pricing:** One-time purchase, no subscription: Mac $49.99, iPhone $9.99, iPad $19.99 (~$80 total for full suite, ~$60 without iPad)
- **Storage & sync:** Proprietary Things Cloud sync service (not user-visible files); not iCloud-based, not Markdown

**Key features**

- Two-tier organization: Areas (e.g. Work, Personal) containing Projects containing To-Dos, plus tags
- Today list plus a distinctive 'This Evening' section within Today
- Start date ("when") separate from Deadline - tasks stay hidden until their start date
- Quick Entry global keyboard shortcut with full natural-language date/time parsing ("call dentist thursday 3pm")
- Checklists nested inside individual to-dos for sub-steps
- Repeaters for recurring to-dos on custom schedules
- Calendar integration showing native Calendar events inline alongside to-dos
- Upcoming, Anytime, Someday, Logbook built-in smart views
- Widgets for home/lock screen on iOS and macOS
- Magic Plus button and drag-and-drop scheduling

**Strengths**

- Widely praised as the most polished, elegant, distinctly Apple-native task-manager UX
- Areas > Projects > Tasks hierarchy is simple yet sufficient for most personal GTD workflows
- Start-date vs deadline distinction elegantly declutters upcoming/today views
- One-time purchase model, no subscription fatigue
- Best-in-class keyboard-driven Quick Entry on Mac

**Weaknesses**

- No true collaboration/shared task lists - explicitly single-user by design
- Proprietary sync, not iCloud, not open files - fully locked in, no Markdown/export ownership
- No web or Windows/Android app - Apple-only, which also means no cross-ecosystem sharing
- No custom filters/saved queries beyond built-in smart lists - less power-user flexibility than Todoist/OmniFocus
- No native project-management features (no Gantt, no dependencies, minimal subtask hierarchy depth)

**Worth adopting in Notetaker**

- Adopt the Areas > Projects > Tasks organizational hierarchy as a clean mental model for grouping notes/todos above raw folders
- Adopt the start-date vs deadline distinction so today/upcoming views aren't cluttered by tasks not yet actionable
- Adopt the 'This Evening' sub-section pattern within Today for lightweight day-parting
- Adopt in-task checklists as a sub-item mechanism nested within a single todo/note block
- Adopt the global Quick Entry panel (system-wide hotkey capture) pattern for macOS
- Emulate the calm, minimal-chrome visual design language as an alternative aesthetic reference point

### OmniFocus 4

- **Platforms:** macOS, iOS, iPadOS, watchOS (no Windows/Android/web app, though a web client exists for Pro subscribers)
- **Pricing:** Standard Edition one-time $49.99; Pro Edition one-time $99.99 (adds custom perspectives, AppleScript/Omni Automation); iOS/universal subscription alternative at $9.99/mo or $99.99/yr for full-feature access across devices
- **Storage & sync:** Own Omni Sync Server (WebDAV-based) or iCloud sync option available; not Markdown files - proprietary database format

**Key features**

- Projects, tags (formerly 'contexts'), due dates, defer dates, and now a distinct Planned Date type (v4.7) separating 'plan to do' from 'due'
- Custom Perspectives - fully user-defined filtered/saved views combining tags, projects, dates, flags, folders (Pro-only)
- Forecast view - calendar-based view blending due tasks with calendar events
- Nearby perspective / location-based tag triggers (geofencing)
- Fluid Layout adapting item detail density across devices
- Focus mode (iPhone/iPad) to temporarily scope the whole database to selected folders/projects
- Recently added Apple Intelligence integration via Omni Automation scripting (late 2025)
- Apple Watch: full database sync, rewritten complications, watchOS Smart Stack widget support, interactive completion from widgets
- Lock Screen, Control Center, and Action Button integration; tinted-icon-optimized widgets
- Deep GTD-oriented structure: sequential vs parallel projects, project/task dependencies via ordering

**Strengths**

- Most powerful, professional-grade filtering/perspective system of any task manager researched - true power-user tool
- GTD methodology baked deeply into the model (sequential/parallel projects, defer vs due vs planned dates)
- Strong automation story via Omni Automation/AppleScript, now extended with Apple Intelligence
- Flexible sync: choice of Omni's own server or iCloud
- Excellent Apple Watch integration relative to competitors

**Weaknesses**

- Steepest learning curve of the group; UI complexity intimidates casual users
- Most expensive combination of pricing tiers (up to ~$150 one-time for Mac+iOS Pro, or ongoing subscription)
- No built-in team collaboration/shared-list features found in current research - remains single-user focused
- Not Markdown-based, proprietary task database
- Fragmented pricing model (one-time vs subscription) is confusing to evaluate

**Worth adopting in Notetaker**

- Adopt Custom Perspectives as the gold-standard model for user-buildable saved/filtered views in the master To-Do tab - more powerful than Todoist's filter strings for a native app because it can be a real UI builder
- Adopt the three-way date model: Defer (start) / Planned / Due, going a step further than Things' two-way start/deadline split
- Adopt sequential vs parallel project semantics for the project-management layer (task ordering/dependency at the project level, not just Gantt bars)
- Adopt the Focus mode concept - temporarily scoping the whole app UI to one folder/project subtree
- Adopt interactive widget completion (check off a task directly from a Lock Screen/Smart Stack widget without opening the app)

### TickTick

- **Platforms:** iOS, iPadOS, macOS, watchOS, Android, Wear OS, Windows, Linux, web, browser extensions
- **Pricing:** Free tier is unusually generous (unlimited tasks/lists/subtasks, Pomodoro timer included free); Premium $35.99/yr (~$3/mo) or $3.99/mo adds calendar view, timeline view, custom filters, more habit slots, more list/attachment limits
- **Storage & sync:** Proprietary cloud (TickTick/Appstract servers); not iCloud, not Markdown files

**Key features**

- Natural-language quick add for dates/times
- Built-in Pomodoro focus timer with cycle tracking and focus statistics (daily/weekly/monthly, most-productive-hours analysis) - free on all platforms
- Habit tracker: daily/weekly/custom-frequency goals with streak counters, separate from the task list
- Calendar view, Timeline view, Kanban board view, and Eisenhower Matrix view - bundles views competitors charge extra for or omit
- Lists, Folders (grouping lists), and Tags for organization
- Priorities (High/Medium/Low/None), recurring tasks with flexible rules
- Custom filters combining tags/lists/priority/date (Premium)
- Collaboration: shared lists with assignees, comments (available even on free tier to a degree)
- Widgets across platforms; smartwatch apps

**Strengths**

- Most feature-dense free tier of any product researched (Pomodoro + habits + calendar + Kanban + matrix all bundled)
- True cross-platform reach including Windows/Linux/web, unlike the Apple-only Things/OmniFocus
- Genuinely cheap Premium tier ($3/mo) relative to Todoist
- Habit tracking is a distinct, well-built module beyond simple task repetition
- Built-in Eisenhower Matrix view is a distinctive prioritization aid not found in the other four

**Weaknesses**

- UI is more cluttered/feature-crowded than Things or Todoist - the 'does everything' breadth can feel unfocused
- Proprietary cloud, not iCloud, not Markdown-based
- Less refined native-Apple design language than Things/OmniFocus/Reminders
- Collaboration features are basic compared to full PM tools

**Worth adopting in Notetaker**

- Adopt an integrated Pomodoro/focus-timer module tied to individual todos as an optional bundled feature
- Adopt a distinct Habit-tracking module (separate from one-off/recurring todos) with streaks and frequency goals
- Adopt an Eisenhower Matrix view as one of the built-in smart views in the master To-Do tab (urgent/important quadrant)
- Adopt Folders-containing-Lists as a two-level grouping option alongside tags, mirroring Things' Areas/Projects but more list-centric
- Adopt bundling multiple view types (list, calendar/timeline, Kanban, matrix) driven by the same underlying task data, which maps well onto reusing one master To-Do dataset across multiple visualizations in Notetaker

### Apple Reminders

- **Platforms:** iOS, iPadOS, macOS, watchOS, visionOS, web (iCloud.com); iOS 27 (in beta, public beta July 2026, full release Sept 2026) adds new NLP
- **Pricing:** Free, bundled with every Apple device/Apple ID
- **Storage & sync:** Native iCloud sync - the exact sync model Notetaker must replicate; also supports CalDAV for other accounts

**Key features**

- Lists and List Groups (folders of lists)
- Tags: free-form, cross-list, browsable via a Tag Browser
- Smart Lists: auto-populated saved views combining tags, dates, times, locations, flags, and priority - can combine multiple tags
- Natural-language entry: "Remind me to go grocery shopping at 2pm on Thursday" auto-parses date/time
- Siri integration for hands-free voice creation ("Remind me to call the client at 3pm")
- Location-based and time-based reminders (geofenced alerts)
- Priority levels (Low/Medium/High), flags
- Subtasks (indented items within a reminder)
- Shared lists - real-time multi-user collaboration with assignees, notifications on completion
- iOS 27 (beta): expanded conversational natural-language creation similar to new Calendar NLP, plus Visual Intelligence (photograph a flyer/screenshot an event/reminder-worthy content to auto-fill details)
- Widgets on Home Screen/Lock Screen, watchOS complications

**Strengths**

- The only product in this set that is natively, fully iCloud-synced - exactly the sync backbone Notetaker must use
- Free, zero-friction, pre-installed everywhere, deepest OS-level integration (Siri, Shortcuts, Focus modes, Spotlight)
- Smart Lists + Tag Browser is a genuinely strong, easy-to-grasp filtering model for non-power-users
- Shared lists with real-time collaboration work seamlessly for family/small-group use out of the box
- Continual native NLP improvements each iOS cycle (iOS 27 pushes this further)

**Weaknesses**

- No true projects/areas hierarchy or sub-project structure - flat lists only, weaker for larger work
- No labels/priority-combination power comparable to Todoist filters or OmniFocus perspectives
- No karma/gamification, no Pomodoro/habit tracking, no Kanban/Gantt
- Not Markdown/file-based, no notes integration beyond a single text field and one embedded image/attachment
- No cross-platform support outside Apple ecosystem

**Worth adopting in Notetaker**

- Adopt iCloud as the sync transport directly (Notetaker's hard requirement already aligns with this - Reminders is the reference implementation to study for CloudKit-based multi-device task sync reliability and conflict handling)
- Adopt Tags + Smart Lists (saved filter combining tags/dates/priority/flags) as the baseline filtering UX - simpler than Todoist's query language but proven to work for mainstream users
- Adopt native Siri/Shortcuts/Spotlight/Visual Intelligence integration hooks as platform-native extensions unique to being an Apple-native app (a real differentiator vs Todoist/TickTick which can't get this deep OS hooking)
- Adopt real-time Shared Lists (per-list collaborator assignment with completion notifications) as the baseline collaboration model, since it's proven to work well on iCloud infrastructure
- Adopt List Groups (folders containing lists) as a minimal organizational layer above flat lists

### Cross-product takeaways

- None of the five incumbent task managers store data as local Markdown files or use iCloud+file-based sync the way Notetaker's vision requires - only Apple Reminders is iCloud-native, but it uses CloudKit records, not .md files. This is Notetaker's clearest structural differentiator: nobody currently combines Markdown-file-based notes with iCloud-synced todos.
- 'Todoist features' the user likely means, ranked by specificity to Todoist (i.e. adopt these explicitly): (1) Quick Add natural-language parsing for dates/recurrence/priority in one line of text, (2) P1-P4 priority levels, (3) free-form cross-cutting Labels distinct from folder/project structure, (4) saved custom Filters via a query syntax, (5) Karma/streak gamification (optional/toggleable), (6) Sections as sub-grouping within a project.
- Table-stakes features present in nearly all five products (not distinctively 'Todoist', safe to build without attribution): natural-language quick entry, due dates + recurring tasks, priority flags, tags/labels, Today/Upcoming views, notifications/reminders, widgets, basic collaboration via shared lists. These should be assumed baseline requirements for Notetaker's To-Do tab regardless of which competitor 'invented' them.
- Best organizational hierarchy pattern to synthesize: Apple Reminders' List Groups > Lists > Tags + Smart Lists, blended with Things' Areas > Projects > Tasks, blended with Todoist's Projects > Sections > Tasks + Labels + Filters. Given Notetaker's Markdown-notes-first architecture, the natural mapping is: Notes/Folders (like Obsidian) as the container, inline todos aggregate into a flat Master To-Do store that is then sliced by Tags/Labels + Priority + Saved Filters/Smart Views (Todoist/Reminders model) rather than forcing todos into a separate rigid project hierarchy.
- OmniFocus's Custom Perspectives and three-way date model (Defer/Planned/Due) is the most sophisticated filtering and scheduling semantics researched and is worth emulating for power users, but its complexity/cost is exactly what alienates casual users - Notetaker should offer Perspective-like saved views as progressive disclosure (simple by default, powerful when opted into), mirroring how TickTick bundles multiple view types (list/calendar/Kanban/matrix) off one dataset.
- For the project-management layer (Gantt/dependencies), none of the five dedicated task managers researched provide this - it's a genuine gap Notetaker's PM layer can fill, but OmniFocus's sequential-vs-parallel project semantics and dependency-via-ordering is the closest prior art among task managers and should inform the underlying task-dependency model.
- For collaboration, Apple Reminders' real-time Shared Lists (built on CloudKit) is the most directly relevant reference implementation since Notetaker will also be built on iCloud/CloudKit - study it over Todoist/TickTick's proprietary-cloud collaboration models.
- Given the hard iCloud requirement and Markdown-first file storage, Notetaker cannot literally reuse any of these five products' sync backends; the closest architectural analog is Apple Reminders (CloudKit + shared lists) for the todo/reminder layer, while the notes layer has no direct native-Apple analog among these competitors (all five are task-only, none are Markdown notes apps) - Obsidian (not researched here per the brief's scope) remains the actual notes-UX reference, and File-Parser reuse for import/OCR is unique to Notetaker's stated vision with no competitor equivalent found.

## All-in-one workspaces

### Notion

- **Platforms:** macOS, Windows, iOS, Android, Web
- **Pricing:** Free tier (unlimited databases for individuals); Plus/Business/Enterprise tiers (~$8-20/user/mo typical); AI Add-on ~€9.50/mo on Free/Plus, bundled in Business/Enterprise
- **Storage & sync:** Proprietary cloud database (Notion's own backend); no offline-first guarantee, web-based sync

**Key features**

- Block-based rich text/wiki editor; every element (paragraph, heading, image, embed) is a movable block
- Databases support 6 views: Table, Board (kanban), Calendar, Timeline (Gantt-style), Gallery, List
- Relations link two databases (e.g., Tasks ↔ Projects); Rollups aggregate related data (e.g., % tasks complete, sum of hours)
- Page and database templates (including per-database templates that can pre-fill relations/fields)
- Notion AI can extract action items from meeting notes and auto-generate tasks from page content
- Inline databases can be embedded directly inside a note/page
- 2026: AI Agents and credit-based 'Custom Agents' pricing added (from $10/1,000 credits) alongside core plans

**Strengths**

- Extremely flexible relations/rollups model connects notes, tasks, and projects into one relational graph
- Timeline/Gantt view built directly on top of a normal database — no separate PM tool needed
- Templates make recurring structures (meeting notes, project trackers) fast to instantiate
- Huge ecosystem/community templates and integrations

**Weaknesses**

- Desktop app is an Electron wrapper around the web app (400-800MB RAM), not native — sluggish, especially on large workspaces
- Data locked in proprietary format/cloud; no local Markdown files, poor true offline support
- Performance degrades significantly with large databases (thousands of rows/relations)
- No local-first guarantee — everything routes through Notion's servers

**Worth adopting in Notetaker**

- Database 'views' concept — same underlying data (a note's frontmatter/tasks) rendered as table, board, calendar, or timeline
- Relations/rollups pattern — e.g., linking a task's parent project via frontmatter and rolling up % complete for a Gantt/PM view
- Per-template scaffolding for recurring note types (meeting notes, project briefs) that pre-populate frontmatter fields
- AI-assisted action-item extraction from note content into the master to-do list

### Anytype

- **Platforms:** macOS, Windows, Linux, iOS, Android
- **Pricing:** Free tier with 1GB sync storage (generous); Builder plan $99/year/user (128GB, 10 editors/space); Business ~$20/editor/month (20% off annual)
- **Storage & sync:** Local-first: data lives on-device by default, stored in Anytype's own object database (not plain Markdown), end-to-end encrypted P2P sync, optional network sync node

**Key features**

- Block-based editor similar to Notion: paragraphs, headings, images, embeds, code blocks
- Database 'sets' and 'collections' with Table, Board, Gallery, Calendar views built from object types
- Object-based model — everything (note, task, person, project) is a typed 'object' with custom relations/properties
- Peer-to-peer encrypted sync between devices; no mandatory central server
- Graph view for backlinks/relations between objects
- Anytype for Business (2026) adds team/shared-space features

**Strengths**

- True local-first architecture — full offline read/write, data never unencrypted on a server
- Open-source core, strong privacy stance
- Flexible object/type system lets tasks, notes, and projects all interrelate via typed relations
- Not Electron — built on Flutter+Rust, lighter and more consistent across platforms than pure Electron apps

**Weaknesses**

- Proprietary internal object storage format, not human-readable Markdown files — hard to use outside the app or with other tools
- Steeper learning curve than a simple notes app due to object/type modeling
- Sync/collaboration features still maturing relative to Notion
- Smaller ecosystem of templates/integrations

**Worth adopting in Notetaker**

- Local-first, encrypted, device-owned data model as the philosophical target (though Notetaker should use iCloud + plain .md instead of a proprietary object DB)
- Typed 'objects' with custom relations — could inspire a lightweight frontmatter schema (type: task/project/person) driving different views over the same .md files
- Full offline parity between desktop and mobile with no feature gap

### Capacities

- **Platforms:** macOS, Windows, iOS, Android, Web
- **Pricing:** Free tier (unlimited notes/objects, 5GB media, offline access); Pro ~$9.99/mo (~$7.99/mo billed annually)
- **Storage & sync:** Proprietary cloud sync with full offline local caching; changes sync automatically on reconnect (not plain Markdown files)

**Key features**

- Object-based PKM: distinct content types (Notes, Books, People, Projects, Meetings, Ideas) each with structured properties/templates
- Daily notes journal, bidirectional linking, visual graph view
- AI assistant for summarization and content generation
- Cross-device apps: Mac, Windows, iOS, Android, Web (desktop app has now surpassed the web app in capability)

**Strengths**

- Object-type model brings database-like structure without manually building databases (lower friction than Notion)
- Genuinely reliable full offline mode across desktop and mobile
- Cleaner, more opinionated UX than Notion for personal knowledge management
- Native-feeling iOS/Android apps distinct from a thin web wrapper

**Weaknesses**

- Proprietary storage format — no raw Markdown file access, limited portability/export
- Weaker project-management/Gantt/timeline features than Notion or Tana
- Smaller company/ecosystem, template library, and integration surface
- Desktop app technology stack not clearly native (evidence suggests Electron/web-based wrapper)

**Worth adopting in Notetaker**

- Predefined content 'types' (Meeting, Project, Person) with type-specific templates as a UX pattern for structured notes without full manual database setup
- Reliable offline-first sync behavior as UX bar to match with iCloud/CloudKit sync
- Daily-notes-as-hub pattern for capturing tasks/ideas that later get promoted into typed objects/projects

### Tana

- **Platforms:** macOS, Windows, iOS, Android, Web (desktop client via GitHub releases)
- **Pricing:** Free (limited nodes); Plus ~$8/mo; Pro ~$10/mo (higher if billed monthly); Enterprise custom
- **Storage & sync:** Cloud-only — no true local-first/offline mode; desktop app caches recent content but editing offline is unreliable

**Key features**

- AI-native outliner: every bullet is a node; 'Supertags' (#project, #task, #person) attach structured fields to any node
- Tagged nodes can be queried/filtered and rendered as database-like 'Live Search' views (table, board) anywhere in the workspace
- Deep AI integration for auto-tagging, summarization, command-driven workflows
- Free tier capped at ~1000 nodes; Plus and Pro tiers unlock more nodes/AI

**Strengths**

- Supertags are a very elegant, lightweight way to make an outline node instantly become a structured, queryable database record
- Outliner-first structure fits fast capture and later reorganization better than block editors
- Live search views let the same tagged data appear as a table/board anywhere without duplicating it

**Weaknesses**

- Cloud-only architecture — a hard blocker given Notetaker's offline/local file requirement
- Steep conceptual learning curve (supertags, nodes, fields) for casual users
- No plain-text/Markdown file storage — fully proprietary graph database
- Small ecosystem relative to Notion

**Worth adopting in Notetaker**

- Supertag pattern — tagging any note or paragraph (e.g., a checkbox line) with a type that gives it structured fields is directly analogous to inline `#task` or frontmatter-driven tagging Notetaker could use to promote inline todos into the master To-Do tab
- 'Live view' concept — a saved query (e.g., all #task nodes due this week) rendered as a table/board without moving the underlying data, which maps well to scanning Markdown files for todo syntax and aggregating them virtually

### Coda

- **Platforms:** macOS, Windows, iOS, Android, Web
- **Pricing:** Free; Pro ~$12/maker/mo (~$10 annual); Team ~$36/maker/mo (~$30 annual); Enterprise custom
- **Storage & sync:** Proprietary cloud-hosted docs; no offline-first support, no local file storage

**Key features**

- Docs that blend rich text with embedded tables ('building blocks') and app-like interactivity (buttons, formulas, automations)
- Table data can be displayed as Table, Card (gallery), Calendar, or other views within a doc
- Doc Maker vs Editor licensing split — only users who edit structure (add tables/automations) are billed, content editors are free
- Packs/integrations for connecting external services and cross-doc data

**Strengths**

- Doc-Maker/Editor billing model is a genuinely useful cost pattern for teams — cheap for viewers/content editors
- Blends document narrative and structured tables more fluidly than Notion for 'living reports'
- Strong formula/automation layer for building lightweight internal apps

**Weaknesses**

- Heaviest/most complex of the group; steep learning curve for building doc-apps
- Cloud/web-only, no offline mode, no local file storage
- Pricing scales quickly for teams (up to $36/maker/mo)
- Less focused on personal note-taking than on team doc-apps/internal tools

**Worth adopting in Notetaker**

- Blending narrative prose and structured table data within the same document, rather than forcing separate 'database' entities
- View-switching on the same underlying table (table/card/calendar) as a UI affordance for embedded task lists inside a project note

### AppFlowy

- **Platforms:** macOS, Windows, Linux, iOS, Android
- **Pricing:** Free (self-hosted, unlimited) or Free cloud tier (5GB, 2 members); Pro ~$10/user/mo (annual, unlimited storage + AI); self-hosting from ~€9/mo on a VPS
- **Storage & sync:** Local-first: all data stored on-device by default in AppFlowy's own store (Flutter/Rust), optional self-hosted or AppFlowy Cloud sync — no telemetry required

**Key features**

- Open-source, self-hostable Notion alternative: docs, databases (grid/board/calendar), wikis, and lightweight project management
- Block-level rich text editor: headings, toggles, code blocks, inline media, drag-to-rearrange
- Local-first by default — works with zero account, optional self-hosted or cloud sync
- AI features (assistant, chat) increasingly built in as of 2026; used internally by companies like Oracle and Telefónica

**Strengths**

- True data ownership: open source, self-hostable, no forced cloud dependency
- Local-first + optional sync gives the best offline story of the group besides Anytype
- Flutter+Rust architecture is lighter and more consistent than Electron across platforms
- Free/cheap compared to Notion for equivalent docs+database+kanban functionality

**Weaknesses**

- Still has real feature gaps vs. Notion (fewer view types, weaker automation/relations maturity)
- Proprietary internal database format for structured data, not plain Markdown files (docs may be Markdown-adjacent but databases are not)
- Smaller template/plugin ecosystem
- Self-hosting requires technical setup to get full sync experience

**Worth adopting in Notetaker**

- Local-first-by-default philosophy with sync as an opt-in layer, not a requirement — validates that a native app can feel first-class without routing every keystroke through a cloud service
- Grid/board/calendar views built over a lightweight, inspectable data layer rather than a monolithic proprietary cloud DB — closer in spirit to reading structured frontmatter out of Markdown files
- Open format ethos: even where AppFlowy falls short (its DB isn't literally Markdown), the design intent of 'your data, your device' maps directly onto Notetaker's iCloud + .md requirement

### Cross-product takeaways

- All six products converge on the same core UX pattern worth stealing: a single underlying data record (task/note/project) can be rendered through multiple 'views' — table, board/kanban, calendar, timeline/Gantt — without duplicating the data. Notetaker can replicate this by treating parsed frontmatter/inline todo syntax across .md files as the 'database' and building native SwiftUI views (List, Board, Calendar, Gantt) that query/aggregate that data live, rather than building a proprietary database engine.
- Notion's Relations+Rollups and Tana's Supertags are the two strongest patterns for connecting notes to tasks/projects. A markdown-file equivalent: use YAML frontmatter fields (e.g., `project: [[Project X]]`, `status: doing`, `due: 2026-07-15`) plus inline `- [ ] task @project(Project X) #due(2026-07-15)` syntax; a background indexer scans the vault and builds an in-memory relational index (task→project, project→tasks) that powers rollups (% complete, Gantt bars) without ever leaving plain text.
- Cloud-only architectures (Tana, and Notion/Coda in practice) are explicitly disqualifying against Notetaker's hard iCloud-sync + offline requirement — they are useful only as feature/UX references, not architectural models.
- Local-first players (Anytype, AppFlowy) validate that a fully offline-capable, device-owned app with optional sync is viable and increasingly expected in 2026 — but both still use proprietary internal object/database stores rather than plain files, which is exactly the gap Notetaker's plain-.md-plus-frontmatter approach can fill as a differentiator ('Obsidian's file portability + Notion's structured views').
- None of the six competitors are native SwiftUI/Electron-free on Apple platforms in the way Notetaker is planned — Notion and (likely) Capacities/Coda ship Electron desktop wrappers, Tana is web/Electron, while Anytype and AppFlowy use Flutter+Rust (cross-platform but not truly native AppKit/UIKit). A genuinely native SwiftUI app with CloudKit/iCloud sync is a real differentiation point worth emphasizing in Notetaker's positioning.
- Templates (Notion database templates, Capacities object types, AppFlowy page templates) are a near-universal expectation for recurring structures (meeting notes, project briefs, weekly reviews) — Notetaker should support Markdown template files with frontmatter placeholders that auto-populate on note creation.
- For the master To-Do tab specifically: Notion's 'AI extracts action items from notes' and Tana's 'any node can be supertagged as a task inline' both point to the same requirement — todos must be authored inline inside normal notes (checkbox syntax) and automatically aggregated into a separate global view via a background parser/index, not maintained as a separate manually-synced list.
- For the PM/Gantt layer: Notion's Timeline view and Coda's table-to-multiple-views pattern suggest the Gantt/PM layer should NOT be a separate data model — it should be another view over the same task/project frontmatter (start/due dates, project relation, % complete rollup from child tasks), keeping a single source of truth in the .md files.

## Hybrid note + task apps (core differentiator)

### NotePlan

- **Platforms:** macOS, iOS, iPadOS (native Swift apps)
- **Pricing:** Subscription only, no free tier (7-day trial). ~$4.99-8.33/month depending on billing term (annual vs monthly).
- **Storage & sync:** Notes stored as plain .md/.txt files locally on device; syncs via Apple CloudKit by default (developer has no server access to content), with an option to switch to plain iCloud Drive folder sync instead.

**Key features**

- Tasks are plain markdown '* task' or '- task' bullets typed directly in Daily Notes or Project Notes — no special plugin needed, todos are first-class markdown list items
- Scheduling syntax: append '>YYYY-MM-DD' (e.g. '>2026-01-22') or '>today', '>tomorrow', '>nextweek', '>Friday' to a task line to give it a date; can also use [[YYYY-MM-DD]] wiki-date-link style
- Scheduling a task auto-creates a 'reference'/backlink of that exact task appearing in the target Daily Note's References section, without physically moving/duplicating the text
- Saved 'Filters'/perspectives let you build cross-note task views by tag, project/note path, or due date range — effectively a configurable master task list
- Native Calendar/Reminders integration: can show Apple Calendar events inline and create native Reminders from tasks
- Time-blocking view that drags tasks onto a calendar timeline

**Strengths**

- True bidirectional aggregation: checking off (or editing) the task reference shown in a Daily Note actually edits the same underlying line in the source Project Note — they are the same task, not a copy
- Scheduling is lightweight, inline, and keyboard-fast (no wizard/dialog needed)
- iCloud/CloudKit-native sync model is very close to what Notetaker needs to replicate
- Plain markdown files remain portable/readable outside the app

**Weaknesses**

- No free tier, subscription-only, comparatively expensive for a 'markdown files' app
- Task views/filters are less powerful than Amplenote's scoring or Obsidian Tasks' query language
- Project-management features (Gantt, dependencies) are absent — it's note+task, not full PM
- CloudKit-vs-iCloud-Drive sync toggle has historically had rough edges/migration confusion for users

**Worth adopting in Notetaker**

- The '>date' inline scheduling shorthand (or a similar terse date-tag syntax) as the primary way to schedule an inline todo
- Reference-based aggregation model: a todo lives in exactly one file; the Daily Note/master list shows a live reference to it rather than a duplicated copy, so completing it anywhere completes it everywhere
- CloudKit-based sync of plain .md files as the storage/sync architecture — matches Notetaker's hard iCloud requirement while keeping files inspectable in Finder/Files

### Agenda

- **Platforms:** macOS, iOS, iPadOS
- **Pricing:** Free app with core features; Premium in-app subscription ~$14.99/year (iPhone/iPad only) or ~$34.99/year (adds Mac) for premium features (attachments, categories, on-the-go actions, etc.)
- **Storage & sync:** Uses iCloud to sync across Mac/iPhone/iPad; not a plain-markdown-file format — proprietary rich note format, though tasks are pushed out to Apple's native Reminders app.

**Key features**

- Notes are organized on a date-based Timeline (past/present/future) rather than a folder hierarchy
- Tasks inside a note aren't inline markdown checkboxes with custom syntax — instead you turn a line into a task and can attach a native Reminder to it with one tap or the '\remind(tomorrow)' natural-language shortcut, which auto-fills date/time from surrounding text
- Deep native integration with Apple Calendar (link a note directly to a calendar event/meeting) and Apple Reminders (two-way: reminders created in Agenda appear in Reminders app and vice versa)
- 'On the Agenda' flagging surfaces action items across notes into a single follow-up list

**Strengths**

- Best-in-class native Apple Calendar/Reminders integration of any note app researched
- Natural-language date parsing for reminders is fast and low-friction
- Timeline metaphor is a genuinely different (and well-loved) way to browse notes chronologically

**Weaknesses**

- Not markdown-first — proprietary note format, weaker plain-text portability than NotePlan/Obsidian/Noteship
- Task aggregation leans on handing off to Apple Reminders rather than having its own rich in-app master task list/query system
- No project-management layer (Gantt, dependencies)
- Timeline-first organization can fight against project/topic-based organization for larger bodies of notes

**Worth adopting in Notetaker**

- One-tap 'attach a native Reminder to this line' plus natural-language date shortcut, mapped in Notetaker to EventKit/Reminders integration for todos that should also alert
- Deep, frictionless Calendar linking (associate a note with a calendar event) as a pattern for meeting notes
- The 'On the Agenda' cross-note flagged-item concept as a lightweight alternate view alongside the main To-Do tab

### Amplenote

- **Platforms:** macOS, Windows, Linux (web/Electron), iOS, Android, web
- **Pricing:** Free tier + paid tiers: Pro ~$7/mo, Unlimited ~$12/mo, Founder ~$25/mo (adds publishing, Vault Notes, calendar sync, larger uploads, graph view)
- **Storage & sync:** Cloud-hosted proprietary backend (not iCloud, not local files) with its own sync; notes are markdown-ish internally but the product is not a local-file/markdown-on-disk app — data lives in Amplenote's cloud.

**Key features**

- Create a task inline with '[] ' (bracket-bracket-space) markdown shorthand anywhere in note text; becomes an interactive checkbox task
- Natural-language due-date/time entry directly in the task text (no separate dialog needed) sets a 'Start Time' aka due date
- '!' Task Commands Menu (keyboard-driven) for snoozing, assigning due dates, setting recurrence ('/every', '/weekday', '/weekend'), and moving tasks between notes
- Every task carries a computed 'Task Score' (priority/urgency/importance/duration/due-today factors) used to auto-rank the master task list — a distinctive prioritization engine beyond simple due-date sort
- Tasks remain permanently tied to their originating note ("jump to note") even when viewed in the aggregated Tasks view/Calendar; completed tasks move to a Completed section within the same note
- Batch operations: drag-select multiple tasks across the note list to bulk move/reassign them to a different note

**Strengths**

- The Task Score algorithm is a genuinely novel differentiator for auto-prioritizing an aggregated task list instead of just sorting by date
- Aggregation is truly bidirectional and live — the task shown in the master Tasks view/Calendar is the same object as the one embedded in the note (no copy/sync lag)
- Calendar view doubles as a task-scheduling surface, not just an events display
- Cross-platform (unlike NotePlan/Agenda/Noteship which lean Apple-only)

**Weaknesses**

- Not local-file/markdown-on-disk, and not iCloud — for Notetaker's hard iCloud requirement this architecture is directly disqualifying as a model to copy for storage, only for UX
- Pricing scales up quickly for power features (calendar sync gated behind Pro tier)
- No true project/Gantt layer — task lists and note-based organization only
- Proprietary sync stack means no offline-first plain-text guarantee

**Worth adopting in Notetaker**

- '[] ' inline shorthand for creating a task from anywhere in note text (fast, no menu)
- A computed relevance/priority score for auto-sorting the master To-Do tab (blend of due date, flagged priority, recency of note access) instead of only manual sort
- 'Jump to note' affordance directly from any row in the master task list
- In-note 'Completed' section that keeps finished todos visible near their origin rather than only disappearing into the master list history

### Obsidian (core) + Tasks plugin + Dataview plugin

- **Platforms:** macOS, Windows, Linux, iOS, Android (community plugin ecosystem; Obsidian core app is free, Tasks/Dataview are free community plugins)
- **Pricing:** Obsidian personal use is free; Catalyst one-time license ~$25-97 for early builds/support; Obsidian Sync add-on ~$4-8/month (or free self-hosted/third-party sync incl. iCloud via file system if the vault folder is placed in iCloud Drive). Tasks and Dataview plugins are free/open-source.
- **Storage & sync:** Local plain .md files in a user-chosen vault folder; official Obsidian Sync is a paid proprietary sync service, but many users instead point the vault at an iCloud Drive folder for free cross-device sync (unofficial, can have conflict-file issues on mobile).

**Key features**

- Core markdown checkbox syntax '- [ ] task' / '- [x] task' with alternate character states (e.g. '- [/]', '- [-]') supported by themes/plugins for in-progress/cancelled
- Tasks plugin adds structured metadata via emoji shorthand appended to the line: 📅 due date, ⏳ scheduled date, 🛫 start date, 🔁 recurrence rule (e.g. '🔁 every week on Monday' or '🔁 every 7 days when done'), priority emoji, done date ✅
- Tasks plugin 'query' code blocks (```tasks``` fenced blocks with a small DSL, e.g. 'not done \n due before today') render a live, interactive, filtered/sorted list aggregated from every file in the vault — this is the closest analog to a 'master To-Do tab'
- Dataview plugin's DQL 'TASK' query type separately aggregates checkbox items vault-wide into tables/lists for custom dashboards, but is read/report-oriented
- Recurrence handling: 'every X when done' computes the next occurrence from actual completion date rather than the original due date

**Strengths**

- Checking off a task inside a Tasks-plugin query block writes back to and edits the exact source line in the exact source file — genuinely bidirectional, no separate task database
- Extremely expressive metadata (multiple date types, priority, recurrence, tags) fully expressed as plain text appended to a markdown line, so the file stays 100% portable plain text
- Query DSL enables arbitrarily custom 'views' (overdue, this week, by project tag, by priority) without needing a bespoke UI screen per view
- Huge community precedent/mindshare — many users will expect Notetaker's todo syntax to be at least loosely compatible with Tasks-plugin conventions

**Weaknesses**

- Steep setup/learn curve — requires installing and configuring two separate plugins and learning DQL/Tasks query syntax; not usable out of the box
- Dataview's TASK queries do NOT understand recurrence — checking off a recurring task via a Dataview block only marks it done and fails to spawn the next occurrence (known footgun); only the Tasks plugin (or clicking through to source) handles recurrence correctly
- Emoji-based metadata is visually noisy in raw markdown and not self-explanatory to new users
- No native mobile task notifications/calendar integration out of the box — requires further plugins
- Sync is either a paid add-on or an unofficial iCloud-folder workaround with known conflict-file edge cases

**Worth adopting in Notetaker**

- Plain-text-appended metadata philosophy (date/recurrence/priority all live as inline text tokens on the checkbox line, so the .md file alone is the source of truth — no sidecar database)
- Live query-block concept for the master To-Do tab: let it be defined as a filter/sort spec (by date, tag, project, priority) rather than a fixed hard-coded view
- 'When done' vs 'fixed schedule' recurrence semantics as two distinct recurrence modes
- Explicit pitfall to avoid: never let an aggregated/computed view silently break recurrence — Notetaker's master list must always trigger the same recurrence-regeneration logic as completing the task in-note, regardless of which surface the check happens on

### Logseq

- **Platforms:** macOS, Windows, Linux, iOS, Android (Electron/native; open source, free)
- **Pricing:** Free and open-source. Optional paid Logseq Sync service (subscription) for their own cloud sync; otherwise local files only.
- **Storage & sync:** Local plain markdown (or org-mode) files, block/outliner-based; no built-in iCloud sync — users typically self-manage sync via iCloud Drive/Git/Logseq Sync/other file sync placed under the graph folder.

**Key features**

- Outliner-first: every line is a block; tasks are blocks with a leading marker keyword: TODO, DOING, NOW, LATER, DONE, CANCELED, WAITING
- Marker cycling via keyboard shortcut (default Cmd/Ctrl+Enter) rotates a block through its workflow states (e.g. TODO → DOING → DONE, or LATER → NOW → DONE) without typing
- Scheduling via 'SCHEDULED: <date>' and 'DEADLINE: <date>' metadata lines attached beneath the task block (org-mode-derived syntax), distinguishing 'when I plan to start' from 'when it's due'
- Journal (Daily Notes) page automatically surfaces SCHEDULED/DEADLINE tasks due that day at the bottom of the day's journal entry, but by default only shows them ON the due day — they don't persist as visibly overdue without a custom query
- Advanced/custom Datalog queries ({{query ...}}) can build persistent 'master list' views (e.g. all overdue tasks across the graph), but this requires hand-writing Datalog, not a built-in UI

**Strengths**

- Outliner block model naturally supports nested subtasks/checklists with no extra syntax
- Marker-cycling keyboard shortcut is extremely fast for changing task state without touching the mouse
- SCHEDULED vs DEADLINE distinction is a genuinely useful mental model (plan-to-start date vs hard due date) worth carrying over

**Weaknesses**

- Default overdue-task handling is a well-documented pain point/pitfall: unfinished SCHEDULED/DEADLINE tasks silently drop off the journal view once their date passes unless the user writes a custom query to resurface them — a major footgun for a 'master to-do list' expectation
- No built-in aggregated task view/dashboard out of the box — power users must hand-write Datalog queries, which is a steep barrier
- No native calendar/reminders integration
- Org-mode-derived syntax (SCHEDULED/DEADLINE as separate metadata lines rather than inline tags) is more verbose on the page than NotePlan/Tasks-plugin inline tags
- No official iCloud sync

**Worth adopting in Notetaker**

- SCHEDULED vs DEADLINE as two distinct date concepts, not just one due date
- Fast single-keystroke state-cycling (todo → doing → done) as a keyboard shortcut in Notetaker
- Explicit pitfall to avoid: Notetaker's master To-Do tab must NOT let overdue/undone items silently disappear after their date passes — always keep undone items visible (e.g. rolled into an 'Overdue' bucket) unless explicitly completed or rescheduled

### Capacities

- **Platforms:** macOS, Windows, iOS, Android, web
- **Pricing:** Free tier + Pro subscription ~$7.99-9.99/month (annual/monthly); also offers a one-time-payment 'Believer' tier for lifetime updates.
- **Storage & sync:** Cloud-first proprietary sync (instant, no configuration) — not local markdown files and not iCloud; supports Markdown export with front matter for backup/portability but round-tripping loses custom views/queries.

**Key features**

- Object-based model: tasks are a structured object type (not just a markdown checkbox) with typed Properties (date, priority, status, tags, links) attachable to any object type
- Create inline task with '()' + space shortcut or '/task' slash command, or global hotkey Cmd/Ctrl+Shift+T from anywhere
- Linking a task to a note/project/person object makes it automatically resurface in that object's auto-generated Tasks tab (All / Open / Status-Kanban / Scheduled sub-views) — no manual query authoring required
- Built-in task dashboard ships pre-built with Inbox (undated/unstatused), Today (due-today + overdue + scheduled-today), and Scheduled views, sorted by priority then deadline then schedule date
- Nested checkboxes inside a task show a subtle progress ring summarizing sub-item completion without opening the task

**Strengths**

- Zero-config aggregation: linking an object automatically populates that object's task tab — very low friction compared to hand-built queries (Obsidian) or manual filters (NotePlan)
- Pre-built Inbox/Today/Scheduled views ship by default, no setup required — a good UX bar for Notetaker's own To-Do tab defaults
- Typed properties give structured filtering/sorting without users learning a query language

**Weaknesses**

- Proprietary object model, not plain markdown-first — directly conflicts with Notetaker's markdown-first, plain-.md-file requirement
- Not iCloud; cloud-first proprietary backend only
- Markdown export/import is lossy for views, queries, and object typing
- Newer/smaller ecosystem than Obsidian/Notion; less battle-tested at scale

**Worth adopting in Notetaker**

- Default zero-config Inbox / Today / Scheduled trio as the initial tab structure for Notetaker's master To-Do tab, rather than requiring the user to build filters before it's useful
- Auto-populated per-note/per-project 'Tasks tab' (All/Open/Kanban/Scheduled) whenever a todo references that note/project — good pattern for Notetaker's project-management layer
- Subtle progress-ring indicator for a task with nested sub-checkboxes

### Noteship

- **Platforms:** macOS only (native, Mac App Store)
- **Pricing:** Sold as an app-store app; reporting is mixed/inconsistent between one-time purchase and subscription/free-trial model as of 2026 — appears to have shifted toward a free tier plus Pro upgrade rather than pure one-time purchase.
- **Storage & sync:** All data stored 100% locally on the Mac as open-standard HTML files in ordinary Finder folders (not iCloud-native, not markdown — HTML-based); no built-in cross-device cloud sync (relies on the user placing the folder under iCloud Drive/Dropbox themselves).

**Key features**

- Combines notes, to-dos, and reminders into one 'Personal Information Manager' concept
- Bi-directional links/backlinks work not just between notes but between notes, todos, and reminders anywhere inside any note — todos and reminders are addressable/linkable objects, not just checkbox text
- Built-in Calendar view surfaces notes and reminders together on a monthly/weekly grid
- Spreadsheet-style view available for structured/tabular data alongside notes
- Simple folder/notebook structure directly mirrored in Finder

**Strengths**

- Strong data-ownership/local-first story (plain files visible in Finder, no lock-in)
- Backlinking todos/reminders as first-class linkable entities (not just checkbox text) is a distinctive idea
- Calendar + spreadsheet + notes in one lightweight native Mac app shows feasibility of a small solo-dev-scale feature set similar to what Notetaker needs

**Weaknesses**

- Mac-only — no iOS/iPadOS app, which fails Notetaker's cross-device requirement outright and shows the risk of skipping mobile
- HTML-based storage rather than markdown — not directly reusable as a model for Notetaker's markdown-first requirement
- No native cloud sync built in — user must bolt on iCloud Drive/Dropbox themselves, with attendant conflict risk on HTML files (worse merge story than plain markdown)
- Small niche product with limited ecosystem/community and unclear long-term pricing model

**Worth adopting in Notetaker**

- Treating todos and reminders as backlink-addressable objects (linkable from anywhere, not just plain checkbox text) — Notetaker could give each todo a stable ID so it can be @-referenced/linked from other notes
- Simple, transparent Finder-visible folder-per-notebook structure as the mental model for how notes map to the iCloud Drive container
- Cautionary example: local-only, single-platform storage (or non-native sync) is a dead end for a note+task app that wants a loyal cross-device user base — reinforces why Notetaker's hard iCloud multi-device requirement is correct

### xTiles

- **Platforms:** macOS, Windows, web, iOS, Android
- **Pricing:** Free tier (unlimited blocks/pages/projects, 5MB/file storage, 3 workspaces, 10 guests) + Plus ~$15/month (unlimited storage, recurring tasks, premium templates, Google Calendar integration) + Family ~$25/mo + Team ~$35/mo; also lifetime-access IAP options (~$149.99+).
- **Storage & sync:** Cloud-hosted proprietary backend with its own sync across platforms; not markdown-file-based, not iCloud.

**Key features**

- Visual, tile/canvas-based board layout (closer to a mood-board/Notion-hybrid) rather than a linear document — notes, tasks, and images arranged freely on a canvas per project
- Tasks are blocks/tiles that can carry due dates, recurrence (paid tier), and be dragged between boards
- Google Calendar two-way integration (paid tier) surfaces and syncs due dates with an external calendar
- Project-oriented organization (each 'project' is a canvas board containing mixed content types) closer to a lightweight PM tool than a pure notes app

**Strengths**

- Canvas/board metaphor is good for visual/spatial thinkers and project-overview-style layouts (relevant to Notetaker's PM layer)
- Generous free tier for a visually-driven tool
- Calendar integration is a paid but genuinely two-way sync, not just export

**Weaknesses**

- Not markdown-first at all — content is block/canvas based, poor fit as a syntax model for Notetaker
- No aggregated 'master task list' concept described in available sources — tasks seem to stay canvas/board-scoped rather than rolling up vault-wide, which is a real gap for Notetaker's aggregation requirement
- Not iCloud; proprietary cloud only
- Pricing is steep for solo users relative to feature depth ($15/mo for basics like recurrence/calendar sync)

**Worth adopting in Notetaker**

- Canvas/board view as an alternate visualization mode for a Notetaker project (complementary to a Gantt chart), letting a project be browsed spatially as well as as a task list
- Nothing in its task-aggregation model is worth copying directly — its lack of a vault-wide master task list is a useful negative example (cautionary, not a pattern to adopt)

### Cross-product takeaways

- The single most important design decision is the aggregation model: best-in-class apps (NotePlan, Amplenote, Obsidian Tasks plugin) make the master To-Do tab a LIVE VIEW/REFERENCE onto the exact same underlying markdown line in the source note, not a copy — checking a box in the master list must edit the source .md file in place, and vice versa. Notetaker should build its master To-Do tab as a query/index over the same on-disk checkbox lines, never a duplicated task database that can drift out of sync with note content.
- A clear split exists between 'inline metadata as plain text on the checkbox line' (NotePlan's '>date', Obsidian Tasks' emoji shorthand, Amplenote's natural-language-in-text) versus 'structured typed objects behind the scenes' (Capacities, Amplenote's Task Score, xTiles). For a markdown-first, iCloud-file-based app like Notetaker, the plain-text-inline-metadata approach is required for portability (files must stay meaningful outside the app and diffable/editable in any text editor), but Notetaker can still parse that plain text into an indexed/queryable model in-app for the master To-Do tab, Today view, etc. — best of both worlds.
- Recommended inline todo syntax for Notetaker, synthesizing the strongest patterns: '- [ ] Task text >2026-07-15 !high #project' — standard CommonMark checkbox, a NotePlan-style '>' date shorthand (with natural-language shortcuts like '>today'/'>tomorrow'/'>friday'), an optional priority marker, and existing tag/project syntax already used for notes — this keeps the raw markdown clean and human-readable, avoiding Obsidian Tasks' emoji clutter.
- Distinguish at least two date concepts on a todo, following Logseq (SCHEDULED vs DEADLINE) and Obsidian Tasks (scheduled/start/due): a 'do this by' due date and an optional 'start working on this' scheduled date, since users conflate these constantly and Notetaker's Todoist/Notion-inspired To-Do tab will need both for smart 'Today' and 'Upcoming' views.
- Critical pitfall to avoid, seen in Logseq: never let an incomplete task silently vanish from the aggregated/'due today' view once its date passes. Overdue items must persistently surface (e.g. auto-roll into an Overdue bucket) until completed, rescheduled, or explicitly dismissed — this is a top user complaint pattern across the space.
- Second critical pitfall, seen in Obsidian Dataview vs Tasks plugin: recurrence logic must be uniformly correctly triggered no matter which UI surface the user checks the box from (in-note, master list, Today view, project Kanban) — a common bug class is a 'read-only' aggregated view that lets you mark done but fails to regenerate the next recurring instance.
- Recurrence needs two distinct modes, both validated by Obsidian Tasks: fixed-schedule recurrence (next instance always N days/weeks from the original due date, e.g. 'every Monday') and completion-based recurrence (next instance is N days after the date you actually finished, e.g. 'every 7 days when done') — Notetaker should support both, toggle-able per todo.
- For zero-friction defaults, Capacities' pre-built Inbox / Today / Scheduled dashboard (populated automatically, no query authoring) is a better onboarding UX bar than Obsidian's fully manual query-block approach; Notetaker's To-Do tab should ship similarly pre-built smart views (Inbox = undated todos, Today = due/overdue, Upcoming, By Project) out of the box, while still allowing Obsidian-Tasks-style custom saved filters for power users.
- None of the researched note+task apps have built-in iCloud-native sync of plain markdown files as their primary architecture except NotePlan (CloudKit, with an iCloud Drive fallback) — this validates that Notetaker's hard iCloud requirement combined with markdown-first storage is a real, differentiated position rather than a solved/crowded niche; NotePlan is the closest architectural precedent to study/borrow from directly for the sync layer.
- For the project-management/Gantt layer (a gap in ALL researched note+task hybrids — none of NotePlan/Agenda/Amplenote/Obsidian/Logseq/Capacities/Noteship/xTiles has real Gantt/dependency tracking), Notetaker has a clean differentiation opportunity: no competitor combines markdown-first notes + live task aggregation + genuine project/Gantt tracking in one native Apple app — this is validated whitespace, not just a nice-to-have.
- Todoist/Notion-style features worth importing into the To-Do tab beyond what these note-apps offer: natural-language quick-add parsing (date/priority/project all typed in one line and parsed out, à la Todoist), a computed priority/relevance score for auto-sorting when no explicit due date exists (à la Amplenote's Task Score), and Notion-style multiple saved views (list/board/calendar/table) over the same underlying todo set.
- Calendar integration best practice, from Agenda: two-way EventKit/Reminders sync with natural-language date parsing at task-creation time (e.g. typing 'tomorrow 3pm' auto-fills a real date) is table stakes for a native Apple app and should be simpler to build well than any of the cross-platform competitors managed, since Notetaker can use EventKit directly rather than a third-party calendar API.

## Project management & Gantt tools

### OmniPlan (Omni Group)


**Key features**

- Native Mac/iPad/Vision Pro app (SwiftUI-adjacent AppKit), universal purchase or subscription
- Interactive Gantt view with drag-and-drop scheduling, task groups/outline hierarchy
- Dependency types: finish-start, start-start, etc., with visual dependency arrows
- Automatic critical path calculation based on dependency chains + slack/float
- Baselines to compare actual vs planned schedule
- Resource management/leveling, cost tracking
- Sync via iCloud Drive (default, recommended by Omni) or Omni Sync Server (WebDAV)

**Strengths**

- True Apple-native feel, keyboard shortcuts, Mac/iPad parity, offline-first with iCloud sync
- Critical path and baseline features are 'real' PM-grade without enterprise SaaS bloat
- One-time or subscription licensing (no per-seat team billing for solo users)

**Weaknesses**

- Steep learning curve for casual/personal users - built for real project managers
- No web or Windows version - Apple-only, no collaboration with non-Apple teammates
- UI density can feel like Microsoft Project transplanted to Mac; not a lightweight personal tool
- $19.99/mo subscription or $199.99-$399.99 one-time - pricey for a solo notetaker feature

**Worth adopting in Notetaker**

- Native iCloud Drive as default sync transport (validates Notetaker's own iCloud requirement)
- Automatic critical-path highlighting computed silently in the background rather than requiring manual setup
- Baseline snapshot concept (save a plan snapshot, diff against live dates) - lightweight version could show 'this task slipped N days'

### Merlin Project (ProjectWizards)


**Key features**

- Native macOS/iPadOS/iOS app built with Apple frameworks
- Hybrid Gantt chart + Kanban board + Mind Map views over one shared data source
- Task dependencies, milestones, resource pool shared across projects
- Work breakdown structure, network diagram (PERT) view
- Import/export MS Project, Excel, MindManager, OPML, XML

**Strengths**

- Genuinely native Apple UX (drag in Gantt feels like manipulating native views, not a web view)
- Kanban/Gantt/Mind-map switch on the *same* task model is a strong UX pattern for a personal PM layer
- Subscription tiers scale from cheap 'Express' (iPhone-only-ish, $4.99/mo) up to full Mac app

**Weaknesses**

- Subscription-only now (no perpetual license option as of 2026) - recurring cost for occasional personal use
- Feature-rich enough to intimidate a solo/personal user (resource pools, budgets, risk register)
- Still a separate app from note-taking - no integration between markdown notes and its project data

**Worth adopting in Notetaker**

- Single underlying task record exposed through multiple views (Gantt/Kanban/list) - exactly the multi-view pattern Notetaker should offer for its PM layer
- Mind-map view as an alternative visualization for early-stage project planning before tasks have dates

### Asana


**Key features**

- Timeline (Gantt-style) view: horizontal bars with start/end dates and dependency arrows
- Drag-and-drop rescheduling; dependent tasks auto-shift and notify next assignee
- Milestones as zero-duration markers on the timeline
- Subtasks appear nested on timeline for complex workstreams
- 'Highlight critical path' toggle in Gantt options
- List, Board (Kanban), Timeline, Calendar views over the same task list
- Personal (free, 2-user cap as of Nov 2025), Starter ~$13.49/user/mo, Advanced ~$30.49/user/mo

**Strengths**

- Very polished drag-to-reschedule interaction, arguably the UX benchmark for simple dependency editing
- Same task object surfaces in list/board/calendar/timeline with zero duplication - good multi-view precedent
- Milestones are lightweight (just a diamond marker), not a heavyweight object type

**Weaknesses**

- Timeline/Gantt view is paywalled (Starter plan or above) - not available to true free/personal users
- Dependencies are essentially finish-to-start only in practice; no float/resource leveling depth
- Built for team collaboration (assignees, @mentions, portfolios) - overkill chrome for a single user

**Worth adopting in Notetaker**

- View-switching (List/Board/Timeline/Calendar) over one underlying task store, not separate silos
- Auto-notify/auto-shift on dependency completion - useful even solo, as a 'this pushed your other task' nudge
- Simple diamond-shaped milestone marker distinct from task bars

### Monday.com


**Key features**

- Gantt Chart view/widget with day/week/month/quarter/year zoom
- Dependency column driving 4 dependency types (FS, SS, FF, SF) with cascading date shifts
- Automatic critical path calculation and highlighting (Pro/Enterprise only)
- Baseline snapshot to compare planned vs actual
- Board-centric data model (each 'board' is a flexible table with many possible views)

**Strengths**

- Extremely visual, colorful, approachable Gantt rendering
- Flexible custom-column board model underlies every view (Gantt is just one lens on a table)

**Weaknesses**

- Critical path & milestones gated behind Pro/Enterprise tier - core PM sophistication is monetized away from casual users
- Heavy per-seat SaaS pricing model (2-user free cap) irrelevant/wasteful for a solo local-first app
- Interface built around automations/integrations marketplace - lots of chrome unrelated to personal task tracking

**Worth adopting in Notetaker**

- Zoom control (day/week/month/quarter/year) on the Gantt timeline as a simple UI affordance
- Cascading auto-date-shift when a predecessor moves, with a visible 'downstream impact' indicator

### ClickUp


**Key features**

- Gantt view with FS/SS/FF/SF dependencies; moving a task auto-shifts all downstream dates
- Critical Path toggle and 'Slack Time' toggle showing float/buffer per task
- Baselines (snapshot vs live) and milestone tracking on the same Gantt
- AI 'Super Agents' that monitor timeline for stalled/overdue tasks and flag critical-path risk
- Gantt available even on the Free plan (unlike Asana/Monday)
- List/Board/Calendar/Gantt/Mind Map/Whiteboard views, all over one task model

**Strengths**

- Most generous free-tier Gantt access of the SaaS tools reviewed - full dependency + critical path + slack visualization at no cost
- Slack/float visualization is a nice, rarely-offered-for-free feature that communicates schedule risk simply
- Broadest single-product view menu (list/board/calendar/timeline/mindmap) built on one task schema

**Weaknesses**

- Famously feature-bloated UI - dozens of unrelated modules (docs, whiteboards, chat, AI writer) crowd the surface
- Steep configuration overhead (custom fields, statuses, ClickApps) before a project even feels usable
- AI monitoring/agent layer is unnecessary complexity for a personal single-user tool

**Worth adopting in Notetaker**

- Slack/float indicator per task (not just binary critical-path highlight) - communicates 'how much room do I have' cheaply
- Free, no-tier-gating approach to Gantt/critical path - validates that critical path is cheap to implement and shouldn't be gated in a personal app either

### Linear


**Key features**

- Cycles (sprints), Projects (roadmaps), and Issues as core primitives
- Roadmap 'timeline visualization' showing project-level bars across month/quarter/year (not task-level Gantt)
- Milestones and progress percentage per project, auto-computed from issue completion
- No dependency arrows, no Gantt chart, no resource allocation view by design

**Strengths**

- Deliberately excludes Gantt/critical-path complexity - proof that a lightweight roadmap view can feel 'professional' without full PM machinery
- Extremely fast, keyboard-driven UX; progress bars derived automatically from underlying issue states (no manual % entry)
- Clean project-level timeline is legible at a glance without needing dependency arrows

**Weaknesses**

- Too coarse for anyone who actually needs task-level scheduling/dependencies - not a real Gantt substitute
- No personal/individual-scale story - built entirely around engineering teams and sprints

**Worth adopting in Notetaker**

- Auto-derived progress percentage from child issue/task completion state rather than manual entry - directly applicable to Notetaker's To-Do aggregation
- The 'roadmap bar, not Gantt chart' level of abstraction as the *ceiling* of complexity to offer by default; full Gantt could be an optional deeper view

### TeamGantt


**Key features**

- Pure-play Gantt specialist: fully drag-and-drop timeline editor
- Dependencies set directly by drawing a line on the chart; durations/dates adjust with a click
- Free plan for 1 user/1 project with up to 60 tasks; paid per-user ($24.95-$29.95/mo) or per-project ($10-$19/project/mo) billing
- Board and calendar views in addition to Gantt

**Strengths**

- Considered the cleanest, most direct drag-to-reschedule Gantt interaction of the reviewed tools - minimal chrome, single purpose
- Per-project pricing option is a rare, solo-friendly billing model versus the near-universal per-seat SaaS norm

**Weaknesses**

- Single-purpose tool - no notes, no broader task inbox, would require pairing with something else for non-project todos
- Even its 'free' tier is capped tightly (1 project), signaling the vendor doesn't see solo/personal use as sustainable free usage

**Worth adopting in Notetaker**

- Draw-a-line-between-bars gesture for creating a dependency, rather than a dropdown/picker - most direct/least modal dependency-creation UX reviewed

### Microsoft Project


**Key features**

- Full enterprise Gantt with drag-and-drop rescheduling, customizable milestone/critical-path color themes
- Path highlighting: click a task to show all predecessors/successors and the full critical path chain
- AI-driven scheduler proposing optimized task sequences and flagging bottlenecks
- Resource management, portfolio dashboards, Power BI/Teams integration
- Tiered plans: Planner free; Plan 1 $10/user/mo (no critical path/baselines); Plan 3 $30/user/mo (adds critical path, baselines, resource mgmt, desktop app); Plan 5 $55/user/mo; perpetual Standard/Professional 2024 also sold

**Strengths**

- The historical benchmark for critical-path/baseline/resource-leveling sophistication - the 'ceiling' of what enterprise Gantt tooling does
- Path-highlighting-on-click is an unusually clear way to expose predecessor/successor chains interactively

**Weaknesses**

- Vast enterprise feature surface (resource leveling, portfolio rollups, EVM) irrelevant to personal or even small-team use
- Even basic critical path is paywalled above the cheapest tier; UI has decades of legacy complexity
- No meaningful personal/individual pricing tier - the whole product is built for org-wide licensing

**Worth adopting in Notetaker**

- Click-a-task-to-highlight-its-full-predecessor/successor-chain interaction as an optional 'explain this dependency' affordance
- Nothing else is recommended for direct adoption - this is the clearest cautionary example of enterprise bloat to avoid

### Notion (Timeline/Gantt database view)


**Key features**

- Timeline is one of several views (table/board/calendar/timeline/gallery) over a shared database of pages
- Requires at least one date-range property on the database to render bars
- Optional 'Dependencies' toggle exposing 'Blocked by' / 'Blocking' relation properties, rendered as arrows
- Dependencies are simple finish-to-start only - no SS/FF/SF types, no automatic critical-path calculation
- Same page/database can also hold arbitrary rich-text/markdown-like content per item

**Strengths**

- Because Timeline is just a view over a normal database (not a separate PM object), any note/task can trivially become a timeline item - very close to the Notetaker task-aggregation model
- Low ceremony: turning on dependencies is a single toggle, not a separate configuration screen
- Same underlying page can carry both project-management metadata (dates, status, assignee) and free-form notes

**Weaknesses**

- Dependency model is too simplistic for anything beyond trivial sequencing (no lag/lead, no SS/FF/SF, no critical path)
- No true critical-path highlighting or baseline/progress-tracking primitives - purely visual sequencing, not real scheduling
- Performance degrades noticeably on large databases; timeline can feel sluggish with hundreds of items

**Worth adopting in Notetaker**

- The core architecture: Gantt/Timeline is *just another view* over the same task/note database, not a separate module - this is the single most relevant pattern for Notetaker, where todos already live inside markdown notes
- One-property date-range requirement and single-toggle dependency enablement as a model for progressive disclosure - PM features stay invisible until a note/project actually needs them

### Cross-product takeaways

- Every product this study covers converges on the same architecture worth copying: a Gantt/timeline is not a separate app or data silo, it is one more *view* (alongside list/board/calendar) rendered over the same underlying task records. Notetaker should build its PM layer the same way - todos aggregated from markdown notes ARE the Gantt items, not a duplicate project-task type.
- The near-universal minimum viable Gantt feature set across all nine tools is: (1) drag-and-drop bars to reschedule, (2) finish-to-start dependencies drawn as arrows, (3) milestones as zero-duration diamond markers, (4) automatic critical-path highlighting computed from dependencies+float with zero manual configuration, and (5) percent-complete/progress derived automatically from child task completion rather than manually typed in (Linear's approach). This is the recommended baseline for Notetaker.
- Advanced dependency types (start-start, finish-finish, start-finish), resource leveling/pools, baselines-as-a-formal-object, budget/cost tracking, and EVM-style reporting (Microsoft Project, OmniPlan, Merlin Project territory) are consistently cited as enterprise-only value that solo/personal users don't reach for - explicitly avoid building these into v1; if added later, keep them behind a progressive-disclosure toggle exactly like Notion's single 'Dependencies' switch.
- Critical path should NOT be a premium/gated feature the way Asana, Monday.com, and MS Project treat it - ClickUp's decision to give critical path and slack-time away for free (even on its Free plan) shows it's cheap to compute and is exactly the kind of 'feels professional' touch a personal app can offer without a paywall.
- Native Apple apps (OmniPlan, Merlin Project) already validate iCloud Drive as the default, Apple-blessed sync transport for project files - reinforcing Notetaker's hard requirement, and suggesting project/task metadata can live as sidecar frontmatter or a lightweight index file alongside the markdown notes rather than a separate database.
- A distinct, lighter tier below full Gantt exists and works well for many personal/roadmap use cases: Linear's non-Gantt 'roadmap timeline' (project-level bars, no dependency arrows, auto-computed progress) proves that a simplified timeline view can feel sufficient and 'professional' for lightweight personal project tracking - Notetaker could default new projects to this simpler view and let a user 'graduate' a project to full Gantt (dependencies + critical path) only when it has more than a few tasks.
- Drag-to-reschedule interaction quality is the single most differentiating UX element users notice; TeamGantt's direct draw-a-connector-line-between-bars gesture and Asana's auto-cascading dependent-date-shift-on-drag are the best reference interactions to emulate.
- Recommended minimal but professional-feeling Gantt feature set for Notetaker v1: task bars with drag-resize/reschedule; finish-to-start dependencies via direct drag-to-connect gesture; milestone markers; auto-computed percent-complete from checked-off inline todos; automatic (non-gated) critical-path highlight; simple day/week/month zoom. Defer: SS/FF/SF dependency types, resource pools/leveling, baselines-as-object, budget/cost tracking, portfolio rollups, and AI schedule-risk agents to a possible future 'Pro' layer, if ever.

## Multi-device access

## 1. Apple device matrix

**One universal SwiftUI target (iPhone/iPad/Mac), adaptive per platform:**
- **Navigation**: `NavigationSplitView` gives a free 3-column layout that collapses to a stack on iPhone, a 2-3 column layout on iPad, and a persistent sidebar on Mac — this is the standard pattern for Obsidian-style apps (folder tree → note list → editor).
- **Toolbars**: Use `ToolbarItem`/`ToolbarItemGroup` with platform-conditional placement (`.navigationBarTrailing` on iOS, native toolbar on macOS); Mac additionally gets a **menu bar** (File/Edit/View menus via `CommandGroup`) which iOS/iPadOS lack — needed for keyboard-driven markdown power users.
- **iPad-specific**: multitasking (Split View/Stage Manager) means the app must handle multiple scene instances cleanly (each note/project a separate `Scene`/window group); **Apple Pencil** support matters for handwritten annotation → OCR-to-Markdown via the File-Parser/Docling pipeline, and PencilKit ink layers embedded in notes (as Notes/Freeform/GoodNotes/NotePlan do increasingly, especially post-visionOS 26.2's Logitech Muse spatial-pencil integration into Notes/Freeform).
- **Mac-specific**: a **menu bar extra** (`MenuBarExtra` API) for quick capture is high value — competitor pattern confirmed (SlashNote, Noticky use system-level global hotkeys that fire even in fullscreen apps); recommend `MenuBarExtra` + a registered global hotkey (via `NSEvent.addGlobalMonitorForEvents` or the `KeyboardShortcuts` package) that pops a lightweight capture window writing directly into a Markdown inbox note.
- **Apple Watch companion**: justified by Things 3 and Todoist doing this well — watchOS 26 Smart Stack now surfaces Live Activities from the paired iPhone automatically, and watchOS 26 is expected to open **Control Center to third-party controls** (Things 3.22 already ships a "New To-Do" Control button on watch Control Center with swipe/type/dictate entry). Recommend: (a) a watch complication showing today's open-todo count, (b) a Control Center "Quick Add Todo" control, (c) rely on Smart Stack Live Activity relay rather than building a full watch app initially — full watch apps are expensive relative to value for a v1.
- **visionOS**: **not worth dedicated targeting for v1.** Market research shows no meaningful spatial-computing note-taking adoption data even a year after the visionOS 26.2 update; however, because Notetaker is a universal SwiftUI/iPad-compatible app, it likely runs automatically as a **compatible iPad app on visionOS** with zero extra work, and per Apple's WidgetKit docs, existing iPhone/iPad widgets **automatically become available in visionOS 26** — so ship the iPad target, accept the "runs on Vision Pro" halo effect for free, and defer a native spatial UI until there's demand signal.

## 2. System surfaces

- **WidgetKit widgets**: iOS 18+ widgets are now interactive mini-apps (buttons/toggles via `AppIntent`, no need to launch the app) — build a "Today's Tasks" widget (check off a todo inline) and a "Quick Note" widget (tap-to-capture opens compose). Precedent: NotePlan shipped exactly this progression (static → lock-screen → interactive widgets) and it's their most-cited feature. Recommend Home Screen (task list) + Lock Screen (count/next task) + StandBy (Mac desktop equivalent not applicable, but macOS 14+ desktop widgets are) sizes.
- **Live Activities**: highest value for a **focused/timed task or Pomodoro-style work session** started from the To-Do tab — shows on Lock Screen + Dynamic Island + (as of watchOS 26) automatically relayed into the Watch Smart Stack with zero extra watch code. This is a cheap, high-visibility feature since the relay to Watch is automatic.
- **Control Center controls** (`ControlWidget`, iOS 18+/macOS 15+/watchOS 26): a "New Task" control matching Things 3's approach — build once, available on iPhone Control Center, Lock Screen, Action Button, and (per current watchOS 26 rumor/rollout) Watch Control Center.
- **App Intents / Shortcuts / Siri**: framework confirmed current — a single `AppIntent` ("Add a Task in Notetaker", "Create a Note in Notetaker") plugs simultaneously into Siri, Spotlight, Shortcuts automations, Control Center, and interactive widgets. This is the single highest-leverage system integration to build early because one intent implementation feeds five surfaces.
- **Share extension**: standard `NSExtensionActivationRule`-based Share Extension to send selected text/URL/file (PDF, image, etc.) into a new or existing note — should route non-text payloads (PDF/DOCX/image/audio) through the existing File-Parser/Docling pipeline for markdown conversion, reusing that app's engine rather than rebuilding OCR/transcription.
- **Quick-capture global hotkey (macOS)**: covered above via `MenuBarExtra`; competitor precedent (SlashNote, Noticky) confirms this is expected table-stakes for a menu-bar-resident note app on macOS 26 Tahoe.

## 3. Continuity

- **Handoff**: implement via `NSUserActivity` (SwiftUI `.userActivity()` / `onContinueUserActivity()`); as of recent SwiftUI, `NSUserActivity` payloads can be `Codable` typed structs, simplifying passing "which note/cursor position was open" between devices. Low effort, expected default behavior for any serious Apple-ecosystem note app.
- **Universal Clipboard**: works automatically once Handoff/Bluetooth/Wi-Fi proximity is enabled system-wide — no app code required beyond standard `UIPasteboard`/`NSPasteboard` use; just don't do anything unusual with clipboard formats that would break it.
- **State restoration**: use `NSUserActivity` as a lightweight "resume where I left off" mechanism (open note, scroll/cursor position, active project view) — Apple's guidance is to keep the activity payload lightweight so it doesn't slow launch.

## 4. Non-Apple access (plain .md files in iCloud Drive) — what works, what conflicts

**Works:**
- **iCloud.com/iCloud Drive web (icloud.com/iclouddrive)**: browser-based read/upload/download of the raw .md files from any OS, no client install needed.
- **iCloud for Windows** (Microsoft Store app, current in 2026): adds an "iCloud Drive" node in File Explorer; files sync bidirectionally and plain-text edits from a Windows text editor (VS Code, Notepad++) will propagate back to Apple devices like any other iCloud Drive file.
- Any Mac/iOS Markdown-capable editor pointed at the same iCloud Drive folder (MarkText, 1Writer, Ulysses, Taio) coexists fine for **read** access and generally for edits **if only one app/device edits at a time**.

**Conflicts to actively warn users about (and design around):**
- **Obsidian + iCloud Drive is a documented failure mode**: multiple Obsidian forum threads (2025-2026) report iCloud on Windows creating large numbers of duplicate files when a vault is pointed at an iCloud Drive folder — root cause is that Obsidian's own change-detection races against iCloud's sync engine, which is not designed for the many-small-frequent-writes pattern a live-editing app produces at typical text-editor granularity. Apple's guidance (and general best practice) is "use only one sync engine per vault/folder" — mixing iCloud Drive sync with a second sync client (Obsidian Sync, Dropbox, Syncthing) pointed at the same folder guarantees `filename (conflicted copy).md`-style duplicates.
- **iCloud's conflict resolution is opaque and app-uncontrollable**: if two devices/apps edit the same file before iCloud has propagated the prior change, iCloud will pick a winner or write a conflicted copy — the editing app (including Notetaker itself, or a third-party editor sharing the folder) cannot always intervene, since iCloud — not the app — owns the sync engine. Apple's own recommended mitigation for document-based apps is proper `NSFileCoordinator`/`NSFilePresenter` usage (Notetaker must implement this correctly for its own read/write, but this doesn't protect against a *second, uncoordinated* app like Obsidian or a raw text editor writing to the same file without going through iCloud's coordination APIs at all).
- **Practical recommendation for Notetaker**: (1) implement NSFileCoordinator/NSFilePresenter correctly internally; (2) document clearly for users that pointing an *additional* sync-capable tool (Obsidian, a second cloud sync client) at the same folder is unsupported/risky, distinct from simply *viewing/occasionally editing* a file via a plain text editor which is lower-risk; (3) consider a lightweight in-app conflict banner that detects `*.md` "conflicted copy" siblings (a known iCloud artifact pattern) and offers a merge/resolve UI, since this will happen to some users regardless of warnings.

## 5. Competitor coverage of this device matrix (and cost/value ranking)

| Surface | Bear | NotePlan | Things 3 | Todoist | Cost to build | Value |
|---|---|---|---|---|---|---|
| Widgets (Home/Lock) | Yes | Yes (added incrementally: static → lock screen → interactive) | Yes, Smart Stack | Yes, incl. task add | Medium | **High** |
| Watch complication | Yes (launches record-note action) | **No** (explicitly requested by users, unbuilt) | Widget + Smart Stack | Full watch app, complications | Low (complication) → High (full app) | High for complication, Low ROI for full watch app |
| Control Center control | — | — | Yes (3.22, watchOS 26) | Yes (iOS 18+) | Low (reuses AppIntent) | **High** |
| Live Activities | Present, noted as "taking over the watch face" (common complaint across apps) | — | — | Not confirmed | Low-Medium (reuses AppIntent/state) | Medium — good for timed tasks, avoid overusing (user complaints about Live Activities cluttering the Watch face are common across apps) |
| Shortcuts/Siri/App Intents | Yes (voice search, journal templates, send todos to Reminders) | Not prominent | Yes, deep | Yes | Low (one AppIntent → 5 surfaces) | **Highest ROI** |
| Share Extension | Yes | Yes | Yes | Yes | Low | **High**, table stakes |
| visionOS | Not primary | Not primary | Not primary | Supported (visionOS 1.0+) as compatible iPad app | ~Free if universal SwiftUI app | Low priority, but "free" compatibility is worth confirming/testing |
| Menu bar quick capture (Mac) | Yes | Yes | — (uses global Quick Entry hotkey historically) | — | Low-Medium | **High** for a markdown-first, keyboard-centric app |

**Ranked recommendation by value-per-implementation-cost:**
1. **App Intents (single "Add Task"/"Create Note" intent family)** — cheapest, feeds Siri + Spotlight + Shortcuts + Control Center + widgets simultaneously.
2. **Share Extension** — low cost, essential for the stated import/convert vision (PDF/DOCX/image/audio → Markdown via File-Parser/Docling reuse).
3. **Home/Lock Screen widgets (today's tasks + quick note)**, interactive via AppIntent — medium cost, high daily-use visibility, and per Apple docs these auto-propagate to visionOS for free.
4. **macOS menu bar extra + global hotkey quick capture** — medium cost, expected by the target power-user (Obsidian-refugee) audience.
5. **Control Center control ("New Task")** — low incremental cost once the AppIntent exists; covers iPhone, Watch (pending watchOS 26 third-party rollout), Action Button, Lock Screen.
6. **Handoff/state restoration via NSUserActivity + Universal Clipboard (free)** — low cost, expected baseline continuity.
7. **Live Activity for a focused task/session** — medium cost; ship but keep opt-in/short-lived given documented user annoyance with Live Activities "taking over" the Watch face.
8. **Watch complication (lightweight, todo count)** — low-medium cost, clear differentiator since NotePlan (closest direct competitor) explicitly lacks this.
9. **Full native watchOS app** — defer; Things/Todoist show it's valuable long-term but is the most expensive item on this list and NotePlan survives without one.
10. **visionOS-native UI** — defer indefinitely absent adoption data; rely on automatic iPad-app + widget compatibility instead.

## iCloud sync architecture implication
Because the hard requirement is plain `.md` files in iCloud Drive (not CloudKit records), Notetaker should use a **ubiquitous container (iCloud Drive Documents)** file-based model with rigorous `NSFileCoordinator`/`NSFilePresenter` (or `NSDocument`/`UIDocument` which builds this in) rather than CloudKit, since CloudKit would not produce human-readable files a user can also open in Windows/Obsidian/a text editor — that plain-file portability is explicitly part of the product vision and is what differentiates it from Apple Notes/Notion-style proprietary-format apps.


**Recommendations**

- Build one AppIntent family (Add Task / Create Note) first — it is the single cheapest integration that simultaneously powers Siri, Spotlight, Shortcuts, Control Center controls, and interactive widgets.
- Use NavigationSplitView + platform-conditional toolbars/CommandGroup for the universal app; add a macOS MenuBarExtra with a global hotkey for quick capture (table stakes for the target power-user/Obsidian-refugee audience).
- Implement the Share Extension early and route non-text payloads through the existing File-Parser/Docling engine so PDF/DOCX/PPTX/image/audio all convert to Markdown on ingest, reusing rather than rebuilding that pipeline.
- Ship Home/Lock Screen interactive widgets (today's tasks, quick note) before building any watchOS app — per Apple's WidgetKit docs these propagate to visionOS automatically, giving Vision Pro presence for near-zero extra cost.
- Add a Control Center 'New Task' control (ControlWidget) once the core AppIntent exists — near-zero incremental cost given Things 3's precedent (Control Center control on iOS and expected watchOS 26 third-party Control Center support).
- Ship a lightweight Apple Watch complication (open-todo count) instead of a full watch app for v1 — differentiates from NotePlan (which explicitly lacks watch support) at a fraction of the cost of a Things/Todoist-style full watch app; revisit a full watch app only after usage data justifies it.
- Use Live Activities sparingly (e.g., an opt-in focused-task/session timer) — watchOS 26 Smart Stack relays them automatically, but competitor user feedback shows Live Activities 'taking over' the Watch face is a common complaint, so default to short-lived/dismissible activities.
- Do not build a native visionOS UI for v1; rely on the universal SwiftUI iPad app running compatibly on visionOS 26, and revisit only if usage telemetry shows meaningful Vision Pro adoption.
- Implement NSUserActivity-based Handoff/state restoration (lightweight, Codable payload of open note + cursor position); Universal Clipboard requires no extra app code.
- Architect storage as iCloud Drive Documents (ubiquitous container) with correct NSFileCoordinator/NSFilePresenter (or NSDocument/UIDocument) usage rather than CloudKit records, since the hard requirement of plain, portable .md files is incompatible with CloudKit's proprietary record model.
- Add in-app documentation/warnings (and ideally a conflict-detection banner for '*conflicted copy*.md' filename patterns) telling users not to point a second sync engine (e.g., Obsidian Sync, Dropbox) at the same iCloud Drive folder Notetaker uses, since this is a documented, reproducible cause of file duplication.

**Risks**

- iCloud Drive's sync engine is not fully controllable by any single app; concurrent edits from Notetaker plus a second app/device before propagation completes can still produce '(conflicted copy)' files even with correct NSFileCoordinator usage on Notetaker's side — this is a platform-level risk, not something engineering alone can eliminate.
- iCloud on Windows is documented to create duplicate files when a second file-watching/sync app (e.g., Obsidian) is pointed at the same iCloud Drive folder; if Notetaker markets 'edit your notes in any editor,' expect support burden from users who add a second sync tool.
- watchOS 26 third-party Control Center support is reported as rumored/rolling out rather than fully documented/stable as of mid-2026 research — Control Center control availability on Watch specifically should be verified against current watchOS 26.x release notes before committing engineering time.
- Live Activities have a documented UX backlash pattern (cluttering/'taking over' the Apple Watch Smart Stack/face) across multiple apps — overusing them for routine todo reminders (vs. genuinely time-bound sessions) risks negative reviews.
- visionOS note-taking adoption/usage data is not publicly available even ~2 years post-launch, so any investment beyond 'free' iPad-compatibility inheritance is speculative and hard to justify with current evidence.
- Full native watchOS apps (Things/Todoist-style) are the most expensive item in this matrix; deferring it is recommended but if users request it strongly post-launch, retrofitting a full watch app onto an app not originally architected for it (data model, sync footprint) could require nontrivial rework.

## Apple platform architecture (technical)

## Notetaker — Apple platform architecture research (macOS 27 / iOS 27, mid-2026)

### 1. Storage architecture for "everything in iCloud" with .md files

Three viable models, and the right answer for an Obsidian-style, .md-file, user-visible vault is a **hybrid** — files in iCloud Drive as source of truth, a local derived index for tasks/metadata.

**Option A — iCloud Drive document storage (ubiquity container + `DocumentGroup`).** SwiftUI's `DocumentGroup`/`FileDocument` auto-integrates with the Files app on iOS/iPadOS and Finder on macOS, and with iCloud Drive as a file provider ([Apple docs](https://developer.apple.com/documentation/swiftui/building-a-document-based-app-with-swiftui), [createwithswift](https://www.createwithswift.com/crafting-document-based-apps-in-swiftui/)). The critical limitation for this product: `DocumentGroup` creates **one scene/window per open document** and has no UI until a document is opened — you cannot host a persistent vault sidebar, a global To-Do tab, or a project view inside it ([Christian Tietze](https://christiantietze.de/posts/2025/07/swiftui-documentgroups-limited/), [marquiskurt](https://marquiskurt.net/documentgroup-papercuts/)). `DocumentGroup` fits single-file editors (Pages-style), not a multi-note vault workspace. So `DocumentGroup` should NOT be the app shell.

**Option B — CloudKit / SwiftData mirroring (`NSPersistentCloudKitContainer`).** Mature and low-boilerplate, but it stores rows in CloudKit's private DB, not user-visible `.md` files in Files/Finder — it fails the "Obsidian-style vault, notes are portable .md files" requirement if used as the primary note store ([joethephish](https://joethephish.me/blog/core-data-vs-cloudkit/), [fatbobman](https://fatbobman.com/en/snippet/fix-synchronization-issues-for-macos-apps-using-core-dataswiftdata/)).

**Option C — Hybrid (recommended).** Store each note as a `.md` file inside the app's **iCloud Drive ubiquity container's `Documents/` subfolder**. Placing the vault under `Documents/` in a container with the `NSUbiquitousContainers` Info.plist key (`NSUbiquitousContainerIsDocumentScopePublic = true`) makes the whole vault **user-visible and browsable in the Files app and Finder** — exactly Obsidian's model. Enumerate/observe the vault with `NSMetadataQuery`; read/write through `NSFileCoordinator`/`NSFilePresenter`; drive downloads of not-yet-materialized files with `startDownloadingUbiquitousItem`. iCloud Drive queues writes while offline and reconciles on reconnect ([Apple iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html), [Level Up / Itsuki](https://levelup.gitconnected.com/swiftui-synchronize-store-files-documents-with-icloud-89b482361148)). Real-world caveat: the iCloud Drive coordination API is low-level and lock/notification-based — budget engineering time ([Zottmann deep-dive](https://zottmann.org/2025/09/08/ios-icloud-drive-synchronization-deep.html), [objc.io](https://www.objc.io/issues/10-syncing-data/icloud-document-store/)).

**Conflict resolution.** Because notes are text files, use `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` to detect conflicts and resolve them (auto line/3-way merge for markdown, or keep-both), then mark resolved ([TN2336](https://developer.apple.com/library/archive/technotes/tn2336/_index.html), [TN2336 via NSFilePresenter](https://developer.apple.com/library/archive/technotes/tn2336/_index.html)). Markdown's text nature makes silent auto-merge far more tractable than binary docs.

**Tasks/metadata/projects.** Keep the `.md` files as the single source of truth. Build a **local, derived index** (todos, tags, wiki-link backlinks, note metadata) by parsing files as `NSMetadataQuery` reports changes — the index is a rebuildable cache, not authoritative, which sidesteps double-sync consistency bugs. Data with no natural home in prose (Gantt dates, dependencies, project structure) should live either in YAML **frontmatter** inside the note or in **sidecar files** (e.g. a hidden `.notetaker/projects/*.json`) in the same iCloud Drive container — this keeps "everything in iCloud" literally true and keeps data portable, rather than splitting it into a separate CloudKit store.

### 2. Markdown editing on Apple platforms

- **`AttributedString(markdown:)`** (SwiftUI/Foundation, cmark-gfm-backed) is good for read-only rendering but collapses syntax markers — unsuitable as the backing store for a live editor ([Medium/Gaitatzis](https://gaitatzis.medium.com/rendering-markdown-in-ios-swift-3e9d8343e372)).
- **Recommended editor engine: TextKit 2** behind an `NSViewRepresentable`/`UIViewRepresentable` wrapping `NSTextView`/`UITextView`, with `NSTextStorageDelegate`/TextKit 2 layout for live syntax styling on every keystroke — the "single-pane live styling" (Obsidian Live Preview / Bear) approach, which keeps native undo/redo, system find, accessibility and Liquid Glass for free.
- **Reference implementations to study/reuse:** [nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) — native AppKit TextKit 2 editor bridged to SwiftUI, with wiki-links, fenced code + syntax highlight, LaTeX, task checkboxes (directly on-vision); [Shpigford/clearly](https://github.com/Shpigford/clearly) — cross-platform NS/UIViewRepresentable, `NSTextStorageDelegate` highlighting, WKWebView preview via cmark-gfm; [SwiftDevJournal/SwiftUIMarkdownEditor](https://github.com/SwiftDevJournal/SwiftUIMarkdownEditor) — SwiftUI live-preview iOS+Mac.
- **Parsing: [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown)** (cmark-gfm AST). Use one parse to drive both editor styling ranges and the todo/tag/backlink extraction feeding the index — single source of truth for structure. For read-only rendered previews, [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) exists but is in maintenance mode (successor "Textual").
- **CodeMirror-in-WKWebView** is powerful (mature editor features) but costs native integration: undo/redo, find UI, accessibility, IPC latency per keystroke, and awkward Liquid Glass theming. Recommend native TextKit 2 over it for a first-party feel.

### 3. SwiftData vs Core Data vs GRDB/SQLiteData for the task/project index (2026)

Because the index is a local derived cache, CloudKit sync on it is optional. Ranking for this use case:

- **SwiftData** — now production-mature in 2026 (parity fixes back-ported to iOS 17), lowest friction, `@Query` reactivity, automatic CloudKit private-DB mirroring if wanted. Weaknesses: limited query expressiveness and **still no shared-database CloudKit sync** for multi-user collaboration ([levelup/Itsuki](https://levelup.gitconnected.com/swiftdata-synchronize-model-data-with-icloud-automatic-with-modelcontainer-e37bce84024c), [3Nsofts](https://3nsofts.com/insights/cloudkit-sync-implementation-ios-data-synchronization-guide)).
- **SQLiteData (Point-Free, GRDB-backed)** — [v1.6.6, June 2026](https://github.com/pointfreeco/sqlite-data), a "fast, lightweight replacement for SwiftData" giving **real SQL** (joins, aggregates, CTEs — valuable for a cross-note todo aggregator and project rollups), `@Query`-style reactive fetching that also works outside SwiftUI, **CloudKit sync AND CloudKit sharing** (which SwiftData lacks) ([Point-Free 1.0](https://www.pointfree.co/blog/posts/184-sqlitedata-1-0-an-alternative-to-swiftdata-with-cloudkit-sync-and-sharing)). Renamed from SharingGRDB.
- **Core Data + `NSPersistentCloudKitContainer`** — most battle-tested and the only Apple-blessed path for mature multi-user CloudKit sharing today, but heavy boilerplate; unnecessary for a solo greenfield single-user app ([fatbobman](https://fatbobman.com/en/snippet/resolving-incomplete-icloud-data-sync-in-ios-development-using-initializecloudkitschema/)).

### 4. Gantt / timeline rendering

- **Swift Charts has no dedicated Gantt mark.** You render Gantt bars with `BarMark` given an x-range (`.value("Start", …)`/`.value("End", …)`) against a categorical y-axis of tasks — fine for a **read-only timeline**. It does not provide drag-to-reschedule, resize-duration, or dependency arrows ([Apple Charts docs](https://developer.apple.com/documentation/Charts)).
- **Interactive Gantt** (drag to move, resize duration, dependency links, zoom) requires a **custom `Canvas` + gesture/`Layout` implementation**, or a commercial component. [Ganttis / DlhSoft](https://dlhsoft.com/ganttis/) ships **SwiftUI wrappers (`GanttChart`, `OutlineGanttChart`) for both macOS and iOS** with drag/resize/dependencies and pinch-zoom built in ([DlhSoft SwiftUI announcement](https://medium.com/ganttis/weve-got-news-swiftui-gantt-chart-views-305ae846ce37)).
- Recommendation: Swift Charts `BarMark` for the MVP read-only timeline; custom `Canvas` layer for editing interactions; buy Ganttis if timeline editing is a headline feature and you want to skip months of work.

### 5. Universal app + WWDC 2025/2026 relevant additions

- **One SwiftUI target** for macOS 27 + iOS 27 with platform conditionals; `NavigationSplitView` adapts to sidebar (Mac/iPad) vs stack (iPhone) automatically — ideal for a vault-list / editor / inspector layout.
- **Liquid Glass** (WWDC 2025, baseline across the "26" OSes and continued in the "27"/"Golden Gate" release): native SwiftUI controls get it automatically on recompile against the 26+ SDK; use the `glassEffect` modifier and `containerConcentric` corner shapes for custom surfaces (toolbars, floating todo capsules) ([Apple newsroom](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/), [WWDC25 session 323](https://developer.apple.com/videos/play/wwdc2025/323/), [LiquidGlassReference](https://github.com/conorluddy/LiquidGlassReference)).
- **WWDC 2026 SwiftUI additions directly relevant here** ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/), [MacRumors](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)): (a) **high-performance document-based apps with direct disk access** — meaningful for fast vault file I/O; (b) **reorder content across lists and grids** — native drag-reorder for the To-Do tab; (c) **lazy subview loading with prefetch** — smooth scrolling over a large vault/note list; (d) refreshed materials/typography/nav+tab bars unifying platforms.
- **Foundation Models framework (iOS 27 / macOS 27)** is highly relevant ([mjtsai](https://mjtsai.com/blog/2026/06/16/apple-foundation-models-in-appleos-27/), [andrew.ooo](https://andrew.ooo/answers/wwdc-2026-developer-tools-xcode-swift-foundation-models-june-2026/), [byteiota](https://byteiota.com/apple-foundation-models-wwdc-2026-multimodal-python-sdk/)): on-device LLM with iOS 27 bringing a **larger model, expanded context, on-device fine-tuning, and full tool calling**; now **multimodal (image input)** and able to call **Vision OCR/barcode tools on-device**; a `LanguageModel` protocol lets you route to cloud models (Claude, Gemini) too; Small Business Program apps under 2M downloads get **Private Cloud Compute at no cloud cost**. Framework is going **open source** with a **Python SDK**. Use cases for Notetaker: auto-summaries, prose→todo extraction, auto-titling, semantic search, and image/PDF OCR in the import pipeline.

### File-Parser reuse constraint (import pipeline)
The File-Parser uses a **Python Docling engine that runs on macOS only** — it cannot execute on iOS/iPadOS. So DOCX/PPTX/PDF→Markdown conversion works natively only on the Mac. On iOS, either (a) fall back to the on-device Foundation Models multimodal + Vision OCR path for images/PDFs, (b) defer heavy conversions until the file syncs to a Mac, or (c) run Docling as a helper service. The new Foundation Models **Python SDK** could also let the Docling pipeline invoke Apple models directly on macOS.

**Recommendations**

- Storage: adopt the HYBRID model. Store notes as .md files in the app's iCloud Drive ubiquity container under Documents/, with NSUbiquitousContainers Info.plist key set so the vault is user-visible in Files.app and Finder (Obsidian-style). This is the only model that satisfies both 'everything in iCloud' and 'portable .md vault'.
- Do NOT use DocumentGroup as the app shell — it is one-document-per-window with no persistent chrome, so it cannot host a vault sidebar, global To-Do tab, or project view. Build a custom NavigationSplitView shell and access files yourself via NSMetadataQuery (enumerate/observe) + NSFileCoordinator/NSFilePresenter (read/write).
- Treat the .md files as the single source of truth and build a LOCAL, derived index (todos, tags, backlinks, metadata) that is rebuildable from the files — do not make the index authoritative or double-sync it.
- For the index store, use SwiftData for the fastest MVP; choose SQLiteData (GRDB, v1.6.6) if you want real SQL joins/aggregates/CTEs for the cross-note todo aggregator and project rollups, plus optional CloudKit sync and CloudKit SHARING (which SwiftData still lacks). Skip Core Data unless you need mature multi-user sharing now.
- Editor: build on TextKit 2 via NS/UIViewRepresentable with live single-pane syntax styling (NSTextStorageDelegate), not a WKWebView/CodeMirror editor and not AttributedString(markdown:). Study/reuse nodes-app/swift-markdown-engine and Shpigford/clearly.
- Parsing: use swiftlang/swift-markdown (cmark-gfm AST) once per note to drive BOTH editor styling ranges and todo/tag/backlink extraction feeding the index.
- Conflict resolution: rely on NSFileVersion.unresolvedConflictVersionsOfItem for concurrent edits; since notes are text, implement auto line/3-way merge with keep-both fallback, then mark versions resolved.
- Gantt: ship a read-only timeline with Swift Charts BarMark (x-range per task) for the MVP; implement interactive drag/resize/dependencies with a custom Canvas+gesture layer, or license Ganttis/DlhSoft (SwiftUI wrappers for macOS+iOS) if timeline editing is a headline feature.
- Universal app: one SwiftUI target, NavigationSplitView, conditional compilation; get Liquid Glass automatically by compiling against the 26+/27 SDK and use glassEffect + containerConcentric for custom surfaces.
- Leverage WWDC2026 SwiftUI additions: direct-disk-access document APIs for fast vault I/O, native list/grid reorder for the To-Do tab, and lazy prefetch for large-vault scrolling.
- Use the Foundation Models framework (iOS27/macOS27) for on-device summaries, prose->todo extraction, auto-titling, semantic search, and Vision-OCR import; route to Claude/Gemini via the LanguageModel protocol when a bigger model is needed. Enroll in the Small Business Program for free Private Cloud Compute.
- Plan the import pipeline around the fact that File-Parser's Python Docling engine is macOS-only: convert on Mac, and on iOS fall back to Foundation Models multimodal + Vision OCR or defer conversion until synced to a Mac.

**Risks**

- iCloud Drive's file-coordination API is low-level, lock/notification-based, and error-prone; developers commonly underestimate it and some abandon it for Dropbox. Budget significant time for download-state handling, coordination, and edge cases (Zottmann, objc.io).
- Making the ubiquity container user-visible in Files means users (and other apps like real Obsidian) can rename/move/delete files out from under you — the index and any sidecar/frontmatter project data must tolerate external mutation and missing files.
- Storing project/Gantt data in sidecar files or frontmatter keeps it portable but makes it hand-editable and corruptible; storing it in CloudKit/SwiftData instead breaks the 'everything in one iCloud vault' portability guarantee. This tradeoff needs an explicit decision.
- SwiftData still lacks shared-database CloudKit sync; if collaboration/sharing is ever on the roadmap, choosing SwiftData now forces a later migration — SQLiteData or Core Data avoid that.
- Swift Charts cannot do interactive Gantt (no drag/resize/dependencies); a custom Canvas implementation is substantial work, and Ganttis is a paid third-party dependency with its own lifecycle risk.
- NSFileVersion conflict auto-merge can still lose or duplicate content on simultaneous heavy edits of the same note across offline devices; a naive last-writer-wins will silently drop edits.
- TextKit 2 live-styling performance can degrade on very large notes or huge vaults; needs profiling and possibly incremental/visible-range styling.
- The Python Docling import engine cannot run on iOS/iPadOS, so full-fidelity import is Mac-only — an iOS-only user cannot convert DOCX/PPTX/PDF without a fallback, which may disappoint mobile-first users.
- Foundation Models on-device capabilities and the free Private Cloud Compute tier depend on device hardware, Apple Intelligence availability, Small Business Program eligibility (<2M downloads), and Apple's evolving terms — treat as enhancement, not a hard dependency.
- The '27' OS details (Golden Gate) are drawn from mid-2026 WWDC coverage and secondary blogs; some specifics may shift before/at GA, so validate against final Apple docs before committing API-level design.

## File-Parser reuse strategy (technical)

## Notetaker conversion architecture — research findings (2026-07-10)

### A. File-Parser as it exists today (verified from repo)
- `app/Package.swift` is an **executableTarget** named `FileParser`, `platforms: [.macOS(.v13)]`, no library product — nothing is currently importable by another app. Reuse requires refactoring into a library product.
- `EngineBridge.swift` is self-contained and depends only on `Foundation` (`Process`, `Pipe`, NDJSON parsing). It resolves the engine by a 5-step search order; step 3 is the **canonical, repo-independent install** at `~/Library/Application Support/File-Parser/engine` (venv python at `.venv/bin/python`). It shells `python -m fileparser.cli convert <input> --to <fmt> --out <dir> [--no-ocr --no-tables --overwrite --images <mode>]` and parses one NDJSON `EngineEvent` per stdout line. `Process`, background `readabilityHandler`, and `waitUntilExit` are **macOS-only** APIs — this file cannot compile for iOS at all.
- Engine is pure Python/Docling (`engine/fileparser/`), lives in a venv, imports PDF/DOCX/PPTX/XLSX/CSV/MD/HTML/AsciiDoc/WebVTT, images (OCR), MP3/WAV (Whisper). `formats.py` is plain data already designed to be surfaced to the Swift UI (`catalog()` / `--list-formats`).

### B. macOS reuse — three options evaluated
1. **Share the installed engine (recommended, lowest effort).** File-Parser already installs to `~/Library/Application Support/File-Parser/engine`. If Notetaker's converter points its resolution at that same path, both apps use one venv/one Docling install and updates apply once. Caveat: creates a runtime dependency on File-Parser being installed; and with App Sandbox, an Application Support path owned by *another* app is outside Notetaker's container.
2. **Bundle/bootstrap its own engine.** File-Parser already ships `scripts/bootstrap_engine.sh` + `engine-src/` inside the .app and installs a venv on first run. Notetaker can carry the same bootstrap and install into its *own* app-support dir. Self-contained and sandbox-clean, at the cost of a duplicate ~Docling install and duplicate update management.
3. **Extract `EngineBridge` + `Models` into a shared SwiftPM package (recommended structural move).** Convert File-Parser's `app` into a package with a **library product** (e.g. `ConversionKit`) containing `EngineBridge.swift` + the `EngineEvent`/`ExportFormat` model types, plus the bootstrap resources. Both File-Parser and Notetaker depend on it. This is the clean long-term answer and is compatible with option 1 or 2 for where the engine physically lives. Note the hardcoded dev path in `EngineBridge` (`/Users/rchaight/.../File-Parser/engine`, lines 42/59) must be parameterized when it becomes shared code.

### C. iOS reality — Python/Docling cannot run; native + service + sync evaluated
**Native Apple frameworks (2026 / iOS 26 baseline) now cover the on-the-go "capture" cases well:**
- **PDF (born-digital):** `PDFKit` `PDFDocument.string` / per-page extraction — direct, no OCR needed.
- **Scans & image OCR + TABLES:** iOS 26 adds **`RecognizeDocumentsRequest`** to the Vision framework, which returns a `DocumentObservation` with **native table detection (rows/columns/cells)** plus reading order — this is new in 2026 and closes much of the historical gap vs Docling for scanned/photographed docs. `VisionKit` `VNDocumentCameraViewController`/`DataScannerViewController` handles capture. ([iOS 26 Vision table detection](https://medium.com/@surajkumbhar904/ios-26-apple-adds-native-table-detection-to-vision-framework-142558ab086a), [VisionKit](https://developer.apple.com/documentation/visionkit))
- **Audio:** iOS 26 **`SpeechAnalyzer` + `SpeechTranscriber`** — fully on-device, long-form, AsyncSequence-based, successor to `SFSpeechRecognizer`; available on iOS/iPadOS/macOS 26. Directly replaces the engine's Whisper path on device. ([SpeechAnalyzer WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechAnalyzer docs](https://developer.apple.com/documentation/speech/speechanalyzer))
- **HTML / RTF:** `NSAttributedString(data:options:[.documentType:.html])` works on iOS.
- **THE GAP — office formats:** `NSAttributedString.DocumentType` supports **`.docx`/`.doc` only on macOS, not iOS** (iOS gets HTML + RTF only). There is **no first-party iOS path for DOCX/PPTX/XLSX**. Third-party `shinjukunian/DocX` only *writes* .docx, it doesn't parse. So DOCX/PPTX/XLSX (and highest-fidelity complex PDFs) have no acceptable native iOS route. ([NSAttributedString.DocumentType](https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype), [DocX](https://github.com/shinjukunian/DocX))

**Self-hosted `docling-serve` (user runs Proxmox homelab):** Docling ships a FastAPI service with a **stable v1 REST API** (`POST /v1/convert/file` and `/v1/convert/source`), container image `quay.io/docling-project/docling-serve`, latest 1.26.0 (2026-06-29), MIT/LF AI & Data. Runs fully local/air-gapped, optional Redis queue for scaling. This gives iOS **full Docling quality over HTTP** with data staying on the user's own hardware. Cost: requires network reachability + homelab uptime; needs auth + TLS if reached off-LAN. ([docling-serve](https://github.com/docling-project/docling-serve), [REST API](https://docling-project.github.io/docling/usage/api_server/rest_api/))

**macOS-convert-then-sync:** Because the product's HARD requirement already puts all notes in iCloud, an iOS import can drop the source into an iCloud "inbox"; the Mac app converts with the full Python engine and the resulting `.md` syncs back. Uses `NSFileCoordinator`/ubiquity container; guarantees eventual full-fidelity conversion with zero new infra. Cost: not instant, requires the Mac to be on. ([iCloud documents](https://developer.apple.com/documentation/UIKit/synchronizing-documents-in-the-icloud-environment))

### D. Is Docling quality worth the complexity?
- Docling's **TableFormer hits ~93.6%** table-structure accuracy vs Tabula 67.9% / Camelot 73.0% — materially better for complex/borderless/spanning tables and multi-column layout/reading order. ([Docling table models](https://deepwiki.com/docling-project/docling/4.2-layout-and-table-structure-models))
- But the calculus **shifted in 2026**: iOS 26 Vision's native table detection makes native "good enough" for scanned/photo tables and simple PDFs, and on-device Speech replaces Whisper. Docling's remaining decisive advantages are (1) **born-digital office formats iOS can't read at all**, and (2) **high-fidelity complex-PDF layout/tables**. So Docling is worth it *selectively*, not universally.
- On-device Docling on iPhone is **not** currently viable: the compact **`granite-docling-258M-mlx`** VLM is optimized for Apple **Silicon Macs** (MLX), and sources do not establish iPhone support — treat it as a Mac-side accelerator, not an iOS path.

### E. Product landscape (for feature framing)
- **Obsidian (2026):** markdown-file/local-first, supports iCloud vaults on Apple-only setups (paid Sync otherwise); mobile improved iCloud-vault load lag but is still slower than desktop. Validates the ".md-in-iCloud" model and shows the perf pitfall to avoid on large vaults. ([Obsidian sync](https://obsidian.md/help/sync-notes))
- **Todoist (2026):** no native Gantt (relies on Ganttify integration); April 2026 added AI natural-language "smart views" and richer NL recurring tasks. ([2026 changelog](https://www.todoist.com/help/articles/2026-changelog-HD3jJAtLd))
- **Notion (2026):** native Timeline/Gantt view with finish-to-start dependencies, critical path, and slip-highlighting — the reference target for Notetaker's PM layer. ([Notion Gantt](https://toolstackpm.com/tools/notion/features/gantt-charts))

**Recommendations**

- Adopt a protocol-driven design: define a `ConversionService` protocol (async `convert(input, to:) -> Markdown` emitting the existing NDJSON-style `EngineEvent` progress) in a shared SwiftPM package, with platform-specific implementations selected at build/runtime. This decouples Notetaker's UI from where/how conversion happens.
- macOS path: refactor File-Parser's `app` into a SwiftPM package exposing a library product (e.g. `ConversionKit`) containing `EngineBridge.swift` + the `EngineEvent`/`ExportFormat` model types + bootstrap resources; have Notetaker's `PythonEngineConverter` depend on it. Parameterize the hardcoded `/Users/rchaight/.../File-Parser/engine` dev path (EngineBridge.swift lines 42 & 59) before sharing.
- macOS engine location: prefer sharing one install, but make Notetaker able to bootstrap its own venv into its OWN app-support dir as the default (sandbox-clean, no hard dependency on File-Parser being installed), while still honoring an explicit override pointing at the existing `~/Library/Application Support/File-Parser/engine` for users who already have it.
- iOS path: build a native-first `NativeConverter` covering the capture cases that matter on iPhone — PDFKit for born-digital PDFs, Vision `RecognizeDocumentsRequest` (iOS 26, native table detection) + VisionKit scanner for images/scans, `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26) for MP3/WAV/voice memos, and `NSAttributedString` for HTML/RTF/plain-text/CSV/Markdown.
- iOS office-format + complex-PDF gap: route DOCX/PPTX/XLSX and high-fidelity table/layout jobs to a self-hosted `docling-serve` on the Proxmox homelab (`POST /v1/convert/file`, stable v1 API, container image), reachable on-LAN and via the user's existing remote-access setup with token auth + TLS.
- Guaranteed fallback that satisfies the HARD iCloud requirement: an iCloud 'import inbox' folder. iOS drops any unconvertible source there; the Mac app (full Python/Docling engine) watches the folder, converts, writes the `.md` back into the vault, and it syncs to all devices. This removes any hard dependency on homelab uptime and makes conversion eventually-consistent by design.
- Layer the iOS strategy as: Tier 1 native on-device (instant, offline, private) -> Tier 2 docling-serve when reachable (full quality, still on user's hardware) -> Tier 3 iCloud-inbox to the Mac (offline-tolerant catch-all). Pick the tier by input type and connectivity; always show progress via the shared `EngineEvent` stream.
- Reuse `formats.py`'s `catalog()`/`--list-formats` output as the single source of truth for supported import/export formats across both platforms, and have the iOS `NativeConverter` advertise a reduced capability set so the UI can gray out or auto-route formats it can't do locally.
- Storage: keep notes as `.md` in an iCloud Drive ubiquity container using `NSFileCoordinator` for every read/write; heed Obsidian's lesson and lazy-load/index large vaults to avoid the mobile iCloud-vault load lag.

**Risks**

- App Sandbox + another app's container: reusing File-Parser's engine at its Application Support path is blocked by sandboxing unless Notetaker ships its own bootstrap/venv or uses a user-granted security-scoped bookmark. Sharing 'just works' only for a non-sandboxed/dev build.
- `EngineBridge.swift` uses macOS-only `Foundation.Process`/`Pipe` and will not compile for iOS; the shared package must guard it behind `#if os(macOS)` or split targets, or the iOS build breaks.
- Python/Docling engine cannot ship inside an App Store macOS app easily either (venv, native wheels, code-signing/notarization of embedded binaries, first-run pip). Bundling adds notarization and app-size complexity; the current bootstrap-on-first-run model needs network access and may trip sandbox/Gatekeeper.
- docling-serve dependency = homelab uptime, network reachability, and security surface: exposing it beyond the LAN needs auth + TLS or the user's notes transit an unauthenticated endpoint. Off-network iOS imports of office formats simply fail unless the Tier-3 iCloud-inbox fallback exists.
- DOCX/PPTX/XLSX have NO viable native iOS parser in 2026 (NSAttributedString .docx is macOS-only; third-party libs only write). Any iOS-only user with office files is fully dependent on docling-serve or the Mac; if neither is available those imports cannot complete on-device.
- Native vs Docling quality gap on complex/born-digital PDFs and nested tables: Vision's iOS 26 table detection targets image/scanned content and won't match TableFormer (~93.6%) on intricate born-digital layouts, so native-first can silently produce lower-fidelity Markdown unless the app flags 'converted on-device (basic)' vs 'full Docling' provenance.
- granite-docling MLX is Mac/Apple-Silicon only; do not plan an on-device iPhone Docling path around it in this cycle.
- Two engine installs (File-Parser + Notetaker) drift in Docling/Whisper versions and double disk/update cost if you bundle separately instead of extracting a shared package; conversely a shared package couples the two apps' release cycles.
- Large-vault mobile performance: Obsidian still reports iCloud-vault load lag in 2026; naive full-vault loading on iOS will feel slow and risks iCloud eviction/partial-download states that NSFileCoordinator must handle explicitly.

## AI integration: Apple Intelligence & Ollama (technical)

## Notetaker AI Research — Current State (mid-2026)

Context note on OS versions: WWDC 2025 shipped Apple's Foundation Models framework in iOS 26 / macOS 26 (Tahoe). WWDC 2026 (June 9, 2026) shipped iOS 27 / macOS 27 with major additions. iOS 26.4 (spring 2026) added key token/context APIs. Notetaker targeting macOS 27 + iOS 27 gets everything below.

---

### 1. Apple Foundation Models framework (FMF)

**The on-device model (2026, "AFM 3")** was rebuilt from the ground up: ~20B-parameter sparse mixture-of-experts that activates only ~1–4B parameters per prompt, with improved instruction-following and tool calling. As of iOS 27 it now accepts **image input directly** (`Attachment(image)` in the prompt builder — UIImage/NSImage/CGImage/CIImage/pixel buffers/file URLs).

**Hard constraint — context window:** the on-device model has a **4096-token context window**. This is the single most important design fact for a notes app. iOS 26.4 added `SystemLanguageModel.contextSize` and `tokenCount(for:)` plus a `usage` property (total / cache-read / reasoning tokens) so you can measure and budget precisely, but 4096 tokens (~3,000 words including prompt + output) means **full-note or full-vault inputs will not fit on-device.** You must chunk, summarize hierarchically, or route to a bigger engine.

**Private Cloud Compute (PCC) model** (accessible through the same `LanguageModelSession` via `PrivateCloudComputeLanguageModel`): **32K-token context**, trained for **reasoning** (`contextOptions.reasoningLevel = .light/.deep`), no API keys / no account setup, privacy-guaranteed (no prompt storage, independently verifiable). **Free for apps with <2M first-time App Store downloads** — effectively free for Notetaker. Requires an entitlement. Also on watchOS 27.

**Guided generation (`@Generable` / `@Guide`)**: constrained decoding built into the framework — the model is forced at the token level to emit valid instances of your Swift types. This is the killer feature for a tasks app: you get type-safe `Todo`, `TaskDate`, `[Tag]` structs back with no JSON parsing/repair. Works on-device and PCC.

**Tool calling (`Tool` protocol)**: model invokes your Swift code mid-generation and folds results back in. WWDC26 added **built-in system tools**: `OCRTool` (structured text from images), `BarcodeReaderTool`, and a **Spotlight-powered Search tool that does fully-local RAG** over personal/on-device content — directly relevant to "search my vault" features.

**Dynamic Profiles** (WWDC26): declarative multi-mode/multi-agent sessions that preserve conversation history while switching instructions, tools, model, and reasoning level per branch — useful later for an agentic "project assistant."

**Model abstraction is now Apple-blessed:** WWDC26 introduced a `LanguageModel` protocol; `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` conform, plus open-sourced `CoreAILanguageModel` (local models) and `MLXLanguageModel` (ANE/Mac GPU). Anthropic and Google are publishing Swift packages for frontier models behind the same API. The framework itself is going **open source** (announced summer 2026), runnable on Linux. This validates the user's plan of a provider abstraction — Apple built the same pattern.

**Also new in macOS 27:** an `fm` CLI (scriptable summarize/extract from the terminal) and a **Python SDK** exposing the same on-device model (relevant given the File-Parser Docling/Python engine — Notetaker's Python side could call the same model).

**Realistically good at:** short-input summarization, action-item/entity extraction, rewriting/tone, classification, tagging, and structured output via `@Generable`. **Weak at / avoid:** long documents (4096-token wall on-device), deep multi-step reasoning and math (route to PCC `.deep` or Ollama), and factual world-knowledge (it will confidently hallucinate — keep it grounded on the note text). Guardrail false positives still exist but are reduced in iOS 27.

**Availability/entitlements:** requires Apple-Intelligence-capable hardware (Apple-silicon Macs; A17 Pro / newer iPhones; M-series iPads). You MUST check `SystemLanguageModel.default.availability` and degrade gracefully (`.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`). PCC needs an entitlement.

Sources: developer.apple.com/videos/play/wwdc2026/241, /339; developer.apple.com/documentation/FoundationModels; machinelearning.apple.com/research/introducing-apple-foundation-models; infoq.com/news/2026/03/apple-foundation-models-context; zats.io/blog/making-the-most-of-apple-foundation-models-context-window; drobinin.com foundation-models real-app writeup; ofox.ai/blog/apple-foundation-models-3-wwdc-2026.

---

### 2. Free platform integrations (no LLM cost, ship-in-MVP wins)

**Writing Tools** — the biggest free win. Proofread (diff accept/reject), Rewrite (friendly/professional/concise + custom "describe your change"), Summarize (summary/key points/list/table). **Any `UITextView`/`NSTextView`/`WKWebView` on TextKit 2 gets it with zero code**; SwiftUI `TextEditor` inherits it. A custom Markdown text engine needs the `UIWritingToolsCoordinator` / `NSWritingToolsCoordinator` API to bridge storage + rendering. Runs on-device with PCC fallback; user text never goes to a third party. **Design implication:** if Notetaker's editor is built on TextKit 2, users get proofread/rewrite/summarize inside every note for free.

**App Intents 2.0 / Siri / Shortcuts (iOS 27)** — expose notes and todos as `AppEntity` + `AppIntent`. New: `IndexedEntity` + Spotlight indexing gives **system-level semantic search and content Q&A over your entities** (Siri/Spotlight understand notes by meaning, not just keywords), App Schemas for richer Siri, streaming responses, multi-turn follow-ups, View Annotations. Powers Shortcuts, Widgets, Action Button, Focus, the Siri app. **SiriKit was formally deprecated at WWDC26** — build on App Intents, not SiriKit. This is how "Hey Siri, add a todo to my Notetaker" and system search work for free.

**Embeddings / semantic search** — `NLContextualEmbedding` (NaturalLanguage): on-device BERT sentence embeddings, **512-dim, 256-token** input, zero cost, private. Pair with a local vector store — `VecturaKit` (MLTensor + Accelerate vDSP, or NLContextualEmbedder backend) or `swift-embeddings`. For higher-quality embeddings you can run MLX embedders locally or call Ollama's embedding endpoint. The 256-token chunk limit means you index paragraph/section chunks, not whole notes.

**Vision / VisionKit OCR** — `RecognizeDocumentsRequest` (WWDC25) returns a hierarchical `DocumentObservation`: groups lines into paragraphs, detects **tables and lists**, reads QR/barcodes, extracts emails/phones/URLs, 26 languages — near-ideal for image/PDF → Markdown with structure preserved. `RecognizeTextRequest` for plain OCR; `DataScannerViewController` for live camera capture. Note FMF's built-in `OCRTool` now wraps this too. Complements (does not replace) the Docling/File-Parser path — Vision is the fast native option for images/scans.

**Speech / SpeechAnalyzer + SpeechTranscriber** (iOS 26+) — on-device long-form transcription, AsyncSequence-based, volatile + finalized results, downloads language assets via system catalog. Benchmarked ~2.2× faster than Whisper on a 7GB file with comparable quality. This is the audio→Markdown transcription engine; pair with an LLM cleanup pass for meeting notes.

Sources: developer.apple.com/documentation/uikit/writing-tools; developer.apple.com/videos/play/wwdc2025/265, /272, /277; wwdc2026/240, /343, /345; developer.apple.com/documentation/appintents/making-in-app-search-actions-available-to-siri-and-apple-intelligence; developer.apple.com/documentation/naturallanguage/nlcontextualembedding; developer.apple.com/documentation/vision/recognizedocumentsrequest; developer.apple.com/documentation/speech/speechanalyzer; github.com/rryam/VecturaKit; ecorpit.com iOS 27 App Intents guide.

---

### 3. Ollama integration from Swift (the homelab engine)

**HTTP API:** `POST /api/chat` (messages, roles), `/api/generate` (single prompt), `/api/embed` (embeddings), and an **OpenAI-compatible** `/v1/chat/completions` surface. Default port **11434**. Streaming is NDJSON (one JSON object per line; `"done":true` terminates) — easy to bridge to Swift `AsyncStream`/`AsyncSequence`. Structured outputs (JSON schema via `format`), tool/function calling (OpenAI-format tool defs), and vision are supported server-side.

**Swift client:** `mattt/ollama-swift` (SPM) supports chat, streaming (`chatStream`), embeddings, structured outputs, tool use, and vision — recommended over hand-rolling, though the raw REST API is trivial to wrap if you want zero dependencies.

**Recommended models, mid-2026, for summarize/extract on a homelab:**
- **Qwen3.5 / Qwen3.6** MoE series is the current sweet spot — e.g. `qwen3` 8B/14B dense on a normal GPU, or the **30B-A3B / 35B-A3B MoE** (only ~3–3.5B active/token) on ~24–64GB, "beats GPT-5-mini" on many benchmarks. Strong at structured output + tool calling.
- **Gemma 3** (`gemma3:4b` edge default, `gemma3:12b` single-GPU multimodal, `gemma3:27b`) and the newer **Gemma 4** (12B in 16GB RAM, native audio; 26B MoE) — good general summarization, multimodal.
- **granite4** and `llama3.3` for reliable function calling; `phi4` for a small footprint.
- Embeddings: `nomic-embed-text` or `embeddinggemma` for vault semantic search if you prefer server-side over NLContextualEmbedding.
- Practical pick for Notetaker: default to a **Gemma3-12B or Qwen3-8/14B** for quality summarization/long-doc work, with `gemma3:4b` as a fast option; use a tool-calling-strong model (qwen3/granite4) for structured extraction.

**Discovery / config UX:** let the user enter `scheme://host:port` (prefill `http://<homelab-ip>:11434`, e.g. the user's .5.x LAN); optionally Bonjour/mDNS auto-discovery on the LAN; **health-check via `GET /api/tags`** and populate a model picker from its response; a "Test connection" button; persist in settings synced (URL only — no secrets) or per-device. Because the server is a homelab box, off-LAN access needs Tailscale/VPN/reverse-proxy — surface a clear "not reachable" state.

**Graceful offline fallback:** Ollama is the "big context / long doc / project drafting" engine but is **not always reachable** (laptop off home network, box down). The provider abstraction must probe reachability (cached, short timeout) and fall back to Apple on-device / PCC, or disable the specific feature with an explanatory affordance — never block the note editor on a network call.

Sources: github.com/mattt/ollama-swift; github.com/ollama/ollama/blob/main/docs/api.md; docs.ollama.com/capabilities/streaming; mljourney.com how-to-use-ollama-with-swift; oneuptime.com 2026-02 ollama-api; morphllm.com/best-ollama-models; huggingface.co/blog daya-shankar/open-source-llms; ollama.com/library.

---

### 4. Feature candidates → best engine

| Feature | Best engine | Rationale |
|---|---|---|
| **Rewrite / proofread / short summarize inside a note** | **Apple Writing Tools** (free, zero-code on TextKit 2) | Ships free, on-device, in-editor; no model to manage. |
| **Extract action items → todos** | **FMF `@Generable`** (on-device for short notes), **Ollama** for long notes | Type-safe `[Todo]` structs via constrained decoding; route long notes >~3k words to Ollama/PCC. MVP. |
| **Natural-language task entry ("call Bob fri 3pm !p1")** | **FMF `@Generable`** on-device + `NSDataDetector`/`Foundation` date parsing | Tiny input, structured output, offline, instant. Ideal on-device fit. MVP. |
| **Note summarization (long)** | **Ollama** (Gemma3-12B/Qwen3) or **PCC 32K** | 4096-token on-device wall; long notes need bigger context. Writing Tools covers the short case. |
| **Semantic search across vault** | **NLContextualEmbedding + local vector store (VecturaKit)**; optionally Ollama embeddings; **IndexedEntity** for system Spotlight | On-device, private, free, offline; index paragraph chunks (256-tok limit). MVP-viable. |
| **Auto-tagging / link suggestions** | **FMF `@Generable`** for tags; **embeddings** for related-note links | Short structured classification on-device; similarity for backlinks. |
| **Meeting transcript → clean note** | **SpeechAnalyzer/SpeechTranscriber** (transcribe) + **Ollama/PCC** (cleanup) | Transcript is long → cleanup needs big context. Transcription is free/on-device. |
| **Project-plan / Gantt drafting** | **Ollama mid model** or **PCC `.deep` reasoning**; skip on-device | Needs reasoning + long output; on-device model too small. Later milestone. |
| **Image/PDF/scan → Markdown** | **Vision `RecognizeDocumentsRequest`** (native) or File-Parser/Docling | Native path preserves tables/lists/structure; Docling for complex/DOCX/PPTX. |

---

### Recommended layered design

Protocol-based provider abstraction mirroring what Apple itself shipped in WWDC26:

- `protocol AIProvider` with async `summarize`, `extractStructured<T: Generable-equivalent>`, `chat/stream`, `embed`, plus a **`Capabilities` descriptor** (`maxContextTokens`, `supportsStructuredOutput`, `supportsStreaming`, `supportsVision`, `isReachable`, `isPrivate`).
- Concrete providers: **`FoundationModelsProvider`** (wraps `SystemLanguageModel` + `PrivateCloudComputeLanguageModel`), **`OllamaProvider`** (homelab), **`NoneProvider`** (deterministic non-AI fallback: regex/NSDataDetector task parsing, keyword search).
- A **router** picks the engine per request from: input token count (measure with `tokenCount(for:)`), task type, provider availability/reachability, privacy setting, and an explicit user preference (Auto / On-device only / Homelab). Small structured tasks → on-device; long/reasoning tasks → Ollama if reachable else PCC; everything degrades to `None`.
- Keep embeddings/vector index as a separate `EmbeddingProvider` (NLContextualEmbedding default, Ollama optional) so search is independent of the chat engine.

### MVP vs later

**MVP:** Writing Tools (free, if editor is TextKit 2); `FoundationModelsProvider` (on-device) for NL task parsing, extract-action-items, short summarize, auto-tag; NLContextualEmbedding semantic search; SpeechAnalyzer transcription; Vision OCR import; App Intents entities for todos/notes (Siri/Spotlight/Shortcuts); the `AIProvider` protocol with FoundationModels + None. All on-device, private, works with the iCloud-only storage requirement.

**Later:** `OllamaProvider` for long-doc summarization, transcript cleanup, and project-plan drafting; PCC `.deep` reasoning tier; Dynamic Profiles for an agentic project assistant; embedding-based related-note/backlink suggestions; discovery UX + Tailscale guidance for the homelab.

**Recommendations**

- Build the note editor on TextKit 2 (UITextView/NSTextView or a coordinator-bridged custom engine) so Apple Writing Tools — proofread/rewrite/summarize — works inside every note for free, on-device, with no model to manage.
- Ship an AIProvider protocol from day one with a Capabilities descriptor (maxContextTokens, supportsStructuredOutput/Streaming/Vision, isReachable, isPrivate) and three implementations: FoundationModelsProvider, OllamaProvider, NoneProvider — mirroring Apple's own WWDC26 LanguageModel abstraction.
- Use Foundation Models @Generable guided generation for all structured extraction (NL task parsing into date/priority/tags, action-item extraction into [Todo]) — it forces type-safe Swift structs at the token level, eliminating JSON parsing/repair. These small-input tasks are the on-device model's sweet spot.
- Treat the 4096-token on-device context as a hard architectural limit: measure every input with tokenCount(for:) and route anything larger (long notes, transcripts, whole-vault ops) to Ollama (if reachable) or Private Cloud Compute (32K, free under 2M downloads, no API keys), never to the on-device model.
- Implement semantic vault search with NLContextualEmbedding (512-dim, on-device, free) plus a local vector store like VecturaKit, indexing paragraph-sized chunks (256-token embedding limit); additionally expose notes/todos as IndexedEntity via App Intents so system Spotlight/Siri get semantic search for free.
- For audio/meeting import, use SpeechAnalyzer + SpeechTranscriber (on-device, ~2.2x faster than Whisper) for transcription, then run an LLM cleanup pass on Ollama or PCC because the transcript exceeds on-device context.
- For image/PDF/scan import, prefer Vision RecognizeDocumentsRequest (preserves tables, lists, paragraphs, 26 languages) as the fast native path, keeping the File-Parser/Docling Python engine for complex DOCX/PPTX cases.
- Make Ollama a later-milestone provider for long-doc summarization, transcript cleanup, and project-plan/Gantt drafting; default to Gemma3-12B or Qwen3-8/14B for quality and a tool-calling-strong model (qwen3/granite4) for structured extraction; use mattt/ollama-swift for chat/stream/embeddings.
- For Ollama config UX: prefill http://<homelab-ip>:11434, offer optional Bonjour discovery, health-check via GET /api/tags, populate the model picker from its response, and add a Test Connection button; persist only the URL (no secrets).
- Always gate Apple Intelligence features on SystemLanguageModel.default.availability and degrade gracefully to the NoneProvider (regex/NSDataDetector task parsing, keyword search) so the app is fully usable on ineligible hardware and offline.
- Build on App Intents 2.0 (not SiriKit, which Apple deprecated at WWDC26) for Siri/Shortcuts/Spotlight integration of notes and todos.

**Risks**

- Apple Intelligence requires eligible hardware (Apple-silicon Macs, A17 Pro+/M-series devices); on unsupported devices FMF and Writing Tools are unavailable, so on-device AI cannot be a hard dependency — every AI feature needs a non-AI fallback.
- The 4096-token on-device context window makes the local model unsuitable for whole-note or whole-vault operations; underestimating this leads to silent truncation or errors. Token budgeting and engine routing must be designed in, not bolted on.
- Ollama on a homelab box is frequently unreachable (laptop off the LAN, server down); without Tailscale/VPN and a cached reachability probe, features that depend on it will hang or fail. Off-LAN access is an explicit setup burden on the user.
- Ollama's 2026 model landscape churns fast (Qwen3.5/3.6, Gemma3/4, granite4, etc.); pinning a single model name risks breakage — pull the model list dynamically from /api/tags and let the user choose.
- Private Cloud Compute and Ollama both send note text off the local device (PCC to Apple servers, Ollama to the homelab); given the product's privacy-adjacent positioning and iCloud-only storage promise, surface clearly which engine processes data and default to on-device where feasible.
- On-device model guardrail false positives (though reduced in iOS 27) can block legitimate note content unpredictably; needs error handling and a retry/fallback path.
- Private Cloud Compute's free tier is conditioned on <2M first-time App Store downloads and requires an entitlement; success at scale or missing entitlement setup could change the cost/availability picture.
- SiriKit is formally deprecated (WWDC26, ~2-3 year removal window); any accidental reliance on it is dead-end — must use App Intents.
- Embedding quality is capped: NLContextualEmbedding is a 256-token, 512-dim BERT model — semantic search over long notes requires careful chunking and may underperform larger MLX/Ollama embedders for nuanced retrieval.
- Foundation Models framework going open source and adding third-party (Anthropic/Google) providers is announced but partly forward-looking (summer 2026); do not build MVP-critical paths on features that have not yet shipped in a stable OS release.

## Security & data-model design (technical)

## Notetaker — Security Architecture & Data-Model Research (verified mid-2026)

### PART A — SECURITY ARCHITECTURE

#### A1. Data at rest — local + iCloud

**Local Data Protection classes.** iOS/macOS file Data Protection is set via `FileProtectionType` (or the POSIX/`NSFileProtection` attribute). Options, strongest→weakest:
- `.complete` — file unreadable while device locked. Too aggressive for a notes app that must background-sync and re-index; a locked phone would block CloudKit push handling and file coordination.
- `.completeUnlessOpen` — readable if already open when lock occurs. Good for the active note being edited.
- `.completeUntilFirstUserAuthentication` (**default on iOS, recommended baseline**) — encrypted at rest, key available after first unlock post-boot. Lets background sync/index work while still encrypting the flash.
- `.none` — avoid.
Recommendation: leave the note store at the iOS default (`completeUntilFirstUserAuthentication`); apply `.complete` only to the SQLite index of *locked* notes and to any decrypted-plaintext scratch files. On macOS, file-level Data Protection is weaker/absent on non-T2/AS layouts, so rely on FileVault (whole-disk) + per-note encryption for locked notes.

**iCloud encryption reality (the critical design constraint).** Apple splits iCloud into *Standard Data Protection* (default) and *Advanced Data Protection (ADP, opt-in)*:
- **Without ADP:** iCloud Drive files (your `.md` notes) are encrypted in transit and at rest, but **Apple holds the keys** — recoverable, and accessible to Apple/legal process. 14 data categories are E2E; iCloud Drive is *not* one of them.
- **With ADP:** the E2E set expands from 14 to **23 categories, and iCloud Drive becomes end-to-end encrypted** (Apple holds no keys). Apple Notes' own content is E2E in this mode.
- **CloudKit:** fields a developer explicitly marks encrypted (`encryptedValues` API + schema declaration) and *all* CloudKit assets are E2E **only when the user has ADP on**; without ADP they are Apple-key-encrypted. CloudKit's per-record system metadata (record names, zone names, timestamps) is never E2E.
- **Sharing caveat:** shared notes/folders remain E2E **only if every participant has ADP enabled**; one non-ADP participant downgrades the share.

**Implication for Notetaker's HARD requirement (notes = `.md` in iCloud Drive):** you *cannot* promise end-to-end encryption for the note bodies unless the user turns on ADP — that is an OS-level setting you cannot enable programmatically. This is the single most important security-messaging fact.

**What the app should promise users (honest tiering):**
1. "Notes are stored as `.md` files in *your* iCloud Drive, encrypted in transit and at rest by Apple."
2. "For zero-knowledge, end-to-end encryption of note contents, enable Apple's Advanced Data Protection (Settings → your name → iCloud → ADP)" — link to Apple's flow, detect ADP status where possible and nudge.
3. "For maximum protection of specific notes, use Locked Notes (below), which are encrypted with a key only you hold, independent of iCloud settings." Do NOT over-promise E2E by default; NotePlan/Obsidian make the same disclosure.

#### A2. App hardening

- **App Sandbox: required** for Mac App Store and strongly recommended otherwise; **Hardened Runtime: required for notarization** (Developer-ID distribution outside the App Store). Both must be on together for a notarized universal app.
- **Entitlements needed:**
  - iCloud: `com.apple.developer.icloud-services` (= `CloudDocuments` for iCloud Drive; add `CloudKit` if you also use a CloudKit index/mirror), `com.apple.developer.icloud-container-identifiers`, and `com.apple.developer.ubiquity-container-identifiers` for the iCloud Drive container. Add `com.apple.developer.ubiquity-kvstore-identifier` only if using key-value store.
  - User-chosen folders (Obsidian-style "open any vault"): `com.apple.security.files.user-selected.read-write` + **security-scoped bookmarks** entitlement `com.apple.security.files.bookmarks.app-scope`. Persist the bookmark, and wrap access in `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`. Note the known 2025 macOS regression: sandboxed apps can lose iCloud Drive/FileProvider access mid-session — re-resolve stale bookmarks and handle the coordinated-read failure gracefully.
  - Ollama on the homelab (LAN): macOS needs `com.apple.security.network.client` (outbound). iOS 26 requires the **Local Network** privacy permission (`NSLocalNetworkUsageDescription`) if the Ollama endpoint is a LAN/mDNS host; a routable/VPN homelab address avoids the local-network prompt but still needs the client entitlement.
  - Hardened Runtime exceptions: keep NONE if possible. Docling/Python (File-Parser reuse) may need `com.apple.security.cs.allow-jit` or `disable-library-validation` if you embed a Python runtime — treat these as smells; prefer running Docling as a notarized helper/XPC service rather than weakening the main app's runtime.

#### A3. Secrets & auth

- **Keychain for Ollama endpoints/tokens.** Store the homelab base URL + any bearer token/API key in the Keychain (`kSecClassGenericPassword`), with access control `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (don't sync secrets to other devices via Keychain unless the user opts in; `ThisDeviceOnly` prevents iCloud Keychain propagation of a homelab credential). Consider `SecAccessControl` with `.userPresence` if the endpoint should require biometric release.
- **App lock (whole-app) with LocalAuthentication.** Use `LAContext` with `.deviceOwnerAuthenticationWithBiometrics` for Face ID/Touch ID/Optic ID and fall back to `.deviceOwnerAuthentication` (passcode). Biometrics are a *gate to release a key*, not the key itself.
- **Per-note locking — mirror Apple Notes/Bear exactly:** derive a symmetric key from a user passphrase via **PBKDF2-HMAC-SHA256** (Apple Notes uses a 16-byte key), encrypt the note body with **AES-GCM** (use CryptoKit `AES.GCM` / `SymmetricKey`). Store only ciphertext + salt + IV in the `.md`/sidecar; never the passphrase. Face ID/Touch ID unlocks a Keychain-wrapped copy of the derived key so the user doesn't retype the passphrase each time — biometrics "enter the password less often," they don't replace it. Support one shared lock passphrase (default) plus optional per-note passphrase; open a "secure session" after first unlock so subsequent same-passphrase notes don't re-prompt. Critical UX warning to surface: a per-note passphrase, if forgotten, is unrecoverable (no key escrow) — exactly Apple's stance.
- For locked notes, keep the *plaintext out of iCloud entirely* — the file that syncs contains ciphertext, so lock protection holds regardless of ADP status.

#### A4. Import safety

- **Untrusted PDFs/DOCX/PPTX via Docling.** Run the Docling/Python conversion in an isolated, sandboxed helper process (XPC service or separate notarized tool) with no network entitlement and minimal file access — a malicious document then cannot reach the network or the note store. Impose resource/time limits (decompression bombs, recursive embeds).
- **Rendered HTML / Markdown preview.** If you render note HTML or imported HTML in a `WKWebView`: disable JavaScript for untrusted content (`WKWebpagePreferences.allowsContentJavaScript = false`), block navigation and subresource loads via `WKNavigationDelegate` (deny non-about: schemes, no remote fetches), and set a strict `WKContentRuleList`/CSP that forbids remote resources so tracking pixels and script injection can't phone home. Prefer sanitizing to an allowlist of tags/attributes *before* render. Never load remote images automatically in imported HTML (privacy: read-receipt pixels).
- **AI processing privacy tiers (make it explicit + user-selectable):** (1) **On-device** — Apple Foundation Models / Core ML / on-device Docling: never leaves the device, best default. (2) **Homelab Ollama** — leaves the device to the user's own LAN/VPN box; data stays on hardware the user controls; use TLS if possible, token in Keychain. (3) **Never third-party cloud** unless the user explicitly opts a note in per-request. Log/surface which tier processed each note. This tiering is a selling point vs. cloud-AI competitors.

---

### PART B — DATABASE / DATA-MODEL DESIGN

#### B1. Source-of-truth architecture (files authoritative, index derived)

**Principle: the `.md` files in iCloud Drive are the single source of truth; the task/project database is a disposable, fully rebuildable index.** This is exactly how NotePlan and the Obsidian-Tasks ecosystem work — NotePlan stores notes as plain Markdown files, syncs them (CloudKit or iCloud Drive mode), and keeps a *local* SQL database it reconciles against the files (it even ships a CloudKit-console reconciliation tool to detect index/file drift). Obsidian-Tasks parses inline `- [ ]` tasks with emoji/dataview metadata out of the files on every load — the vault is truth, the query cache is derived.

**Why derived-index, not SwiftData-as-truth:** the hard requirement is `.md` in iCloud Drive, and users can edit those files in Obsidian/Textastic/Files.app behind your back. If SwiftData were the source of truth you'd have two writers and unresolvable conflicts. Make the DB rebuildable so a "delete DB and re-scan the vault" always converges.

**Sync/consistency strategy:**
- **File → index (inbound):** watch the iCloud Drive container with `NSFilePresenter`/`NSMetadataQuery` (iCloud ubiquitous query surfaces download state + external edits) and `DispatchSource` file-watching on macOS. On change, read via `NSFileCoordinator` (coordinated read prevents reading a half-synced file), parse frontmatter + inline tasks, upsert rows keyed by a stable note id + content hash. Store per-file `mtime` + SHA-256 so unchanged files are skipped on bulk scans. Debounce iCloud's chatty change notifications.
- **Index → file (outbound, e.g. checkbox toggled in the master To-Do tab):** never blind-write. Do a coordinated read of the current file, locate the exact task line (store a byte-range or line-anchor + a task UUID in an inline `^id`/`<!-- id -->` marker so re-flowed text stays addressable), flip `- [ ]`↔`- [x]`, write back with `NSFileCoordinator` write. Then let the inbound watcher reconcile — the DB row is provisional until the file write confirms.
- **Conflict handling:** rely on iCloud Drive's own conflict versions (`.icloud` / conflict siblings); surface conflicts in-app rather than auto-merging Markdown. Because the DB is derived, a lost DB is never data loss.
- **Task identity across edits:** assign each inline task a durable id embedded in the Markdown (e.g. trailing `⛄id:AB12` or hidden HTML comment, NotePlan-style) so toggles/edits from the master list re-target the right line even after the note is reformatted elsewhere.

#### B2. Concrete entity model

**Storage split — what lives WHERE:**
- **In Markdown frontmatter (YAML) — travels with the file, human-editable:** note-level metadata: `id`, `title`, `tags`, `created`, `modified`, `aliases`, `project`, and note-scope project/milestone declarations. Frontmatter is authoritative for note-level attributes.
- **Inline in Markdown body — authoritative for tasks:** `- [ ] Task text 📅 2026-07-20 ⏫ #label @context 🔁 every week ⛔ blockedby:XYZ ^taskid` (Obsidian-Tasks / Tasks-emoji convention). Task *state, text, due, priority, labels, recurrence, dependency refs* live here so they survive in any Markdown editor.
- **Index-only (DB, never written back to files) — derived/queryable:** parsed/normalized columns, FTS index, backlink graph, computed Gantt schedule (start/finish rollups), download status, content hashes, cached render.

**Entities (SwiftData `@Model` or GRDB tables):**

- **Note** — `id` (UUID/stable slug), `filePath` (relative to container), `title`, `frontmatter` (blob/parsed), `contentHash`, `createdAt`, `modifiedAt`, `wordCount`. Relationships: has-many Task, has-many OutLink, belongs-to Project (optional). File-authoritative; row rebuildable.

- **Task** — `id` (matches inline `^taskid`), `noteId` (FK), `lineAnchor`/`byteRange`, `text`, `state` (enum: `open`, `done`, `cancelled`, `scheduled`, `inProgress`), `dueDate`, `scheduledDate`, `startDate`, `completedAt`, `priority` (enum: none/low/medium/high/urgent — Todoist P1–P4 style), `recurrenceRule` (RFC-5545-ish string or parsed struct), `parentTaskId` (subtasks), `sortOrder`. Many-to-many → Label. Task *content* is file-authoritative; scheduling rollups index-only.

- **Label / Tag** — `id`, `name`, `color`, `kind` (`#tag` vs `@context` vs project-label). Many-to-many with Note and Task. Derived from inline `#`/`@` tokens + frontmatter `tags`.

- **Project** — `id`, `name`, `noteId` (the project's "home" note, optional), `status`, `startDate`, `targetDate`, `color`, `description`. Has-many Milestone, has-many Task (via note membership or explicit `project:` field), has-many DependencyEdge.

- **Milestone** — `id`, `projectId` (FK), `name`, `dueDate`, `state`. Has-many Task.

- **DependencyEdge** (Gantt) — `id`, `projectId`, `fromTaskId`, `toTaskId`, `type` (`finish-to-start` default, plus SS/FF/SF), `lag`. This is the graph that drives the Gantt critical-path/roll-up. Store edges index-only but source them from inline `⛔ blockedby:` / `depends:` markers so they're portable.

- **OutLink / Backlink** — `id`, `sourceNoteId`, `targetNoteId` (or unresolved target string), `context`. Powers `[[wikilink]]` graph and backlinks pane; fully derived.

- **IndexMeta** — `schemaVersion`, `lastFullScanAt`, per-file `mtime`+`hash` table for incremental reindex.

**Gantt note:** compute start/finish/critical path in the index by topologically sorting DependencyEdges over Task durations; never persist computed schedule to the `.md` (it's derived and would churn the files).

#### B3. Migration, versioning, FTS

**SwiftData vs GRDB — recommendation: this is the key architecture fork.**
- If you want tight SwiftUI integration and are comfortable on the current stack, **SwiftData** (iOS 26/macOS 26 is schema **version 4.0**, adds class inheritance) supports versioned migration via `VersionedSchema` + `SchemaMigrationPlan` with lightweight stages (add/rename/delete attributes, relationships) and custom stages for data transforms; SwiftData auto-chains v1→…→v5. Michael Tsai's Feb 2026 write-up and WWDC25 session 291 confirm the current pattern. **Caveats (well-documented in 2025–26):** SwiftData migrations remain fragile for non-trivial transforms, custom stages have sharp edges, and FTS support is not first-class.
- **GRDB (SQLite)** is the stronger choice *for this app specifically* because: (a) the whole DB is a rebuildable derived index, so you get little from SwiftData's object-graph persistence guarantees; (b) you need **FTS5**, which GRDB exposes natively and SwiftData does not; (c) migrations are explicit, ordered, testable `DatabaseMigrator` steps — far more predictable than SwiftData for a schema that will churn as task/Gantt features grow; (d) full control over triggers to keep FTS in sync. **Recommendation: GRDB for the task/note index + FTS, with SwiftData reserved only if you later want a synced *CloudKit-backed* object store for app settings.** Because the index is disposable, even a botched migration is recoverable by a full vault re-scan — but still version the schema (`IndexMeta.schemaVersion`) and, on version mismatch you can't migrate cleanly, just drop + rebuild from files.

**Full-text search — use BOTH, for different jobs:**
- **SQLite FTS5 = primary in-app search.** Ships with SQLite, inverted index, BM25 ranking, phrase/prefix/highlight, fast on mobile CPUs and on 10k+ notes. Keep an FTS5 virtual table mirroring Note.title+body, kept current with triggers or explicit upserts during reindex. This is what Obsidian-class search needs.
- **CoreSpotlight = system integration only.** Index notes as `CSSearchableItem`s so they appear in system Spotlight/Safari and support Handoff/deep-links. Apple cautions CoreSpotlight "works best with no more than a few thousand items" and in-app it's weaker than FTS; iOS 26 improved it (skips duplicate indexing) but do NOT use it as your primary search. Index a capped, deduped subset (titles + snippets) to Spotlight; run real queries against FTS5.

**Reindex/migration operational rule:** on launch, compare `IndexMeta.schemaVersion` and each file's `mtime`/`hash`; incrementally reindex changed files; on schema-version bump either run the GRDB migrator (structural) or, when in doubt, full rebuild from the authoritative `.md` files (cheap because files are truth).

**Recommendations**

- Treat iCloud Drive .md files as the single source of truth and make the task/project database a fully rebuildable, disposable derived index (NotePlan/Obsidian-Tasks model) — so external edits and a lost DB never cause data loss.
- Choose GRDB + SQLite FTS5 for the index rather than SwiftData: the store is derived (so SwiftData's persistence guarantees add little), FTS5 is native in GRDB but absent in SwiftData, and GRDB's DatabaseMigrator gives predictable, testable migrations for a schema that will churn with task/Gantt features. Reserve SwiftData only for a possible CloudKit-backed settings store.
- Use FTS5 as the primary in-app search (BM25, phrase/prefix/highlight, scales to 10k+ notes) and CoreSpotlight only for system Spotlight/Handoff integration on a capped, deduped subset — do not rely on CoreSpotlight for primary search.
- Be honest in security messaging: note bodies in iCloud Drive are Apple-key-encrypted by default and only become end-to-end encrypted if the USER enables Advanced Data Protection (you cannot enable it programmatically). Detect/nudge toward ADP and document the 14→23 E2E-category change.
- Implement per-note Locked Notes independent of iCloud: PBKDF2-HMAC-SHA256 key derivation + AES-GCM via CryptoKit, ciphertext-only in the synced file, biometric (Face ID/Touch ID/Optic ID) unlock of a Keychain-wrapped key — mirroring Apple Notes/Bear. This guarantees confidentiality regardless of ADP status.
- Give every inline task a durable id embedded in the Markdown (hidden marker, NotePlan/Tasks style) so master-list checkbox toggles and edits re-target the correct line after external reformatting; write back only via NSFileCoordinator coordinated reads/writes with byte-range/line anchoring.
- Store task state/due/priority/labels/recurrence/dependency refs INLINE in Markdown (Obsidian-Tasks emoji convention) and note metadata in YAML frontmatter; keep only derived data (FTS, backlink graph, computed Gantt schedule, hashes, download state) in the DB and never write computed schedule back to files.
- Ship notarization-required hardening: App Sandbox + Hardened Runtime with NO runtime exceptions; run the reused Docling/Python import engine as an isolated sandboxed XPC helper with no network entitlement so untrusted PDF/DOCX/PPTX conversion cannot exfiltrate or reach the note store.
- For user-chosen vault folders use com.apple.security.files.user-selected.read-write plus app-scoped security-scoped bookmarks (start/stopAccessingSecurityScopedResource), and handle the known 2025 macOS regression where sandboxed apps lose iCloud Drive/FileProvider access mid-session by re-resolving stale bookmarks.
- Store the homelab Ollama endpoint/token in the Keychain as ThisDeviceOnly (afterFirstUnlockThisDeviceOnly) so a LAN credential doesn't sync; request com.apple.security.network.client on macOS and the iOS Local Network permission only if the endpoint is a LAN/mDNS host.
- Expose an explicit, per-note AI-processing tier — on-device (Apple Foundation Models/Core ML) as default, homelab Ollama as opt-in, third-party cloud never unless explicitly opted in per request — and record which tier processed each note.
- Render any imported/untrusted HTML in an isolated WKWebView with JavaScript disabled, all remote resource loads and navigation blocked via a strict content-rule list/CSP, and sanitize to a tag allowlist before render; never auto-load remote images (tracking-pixel privacy).
- Version the index schema (IndexMeta.schemaVersion) and drive reindex off per-file mtime+SHA-256; on an un-migratable schema bump, drop and full-rebuild from the authoritative .md files rather than risking a fragile migration.

**Risks**

- Cannot promise end-to-end encryption for note bodies by default: the hard requirement (.md in iCloud Drive) is only E2E when the user enables Advanced Data Protection, an OS setting the app cannot toggle. Over-promising E2E would be a false security claim; must be disclosed like NotePlan/Obsidian do.
- Multi-writer conflicts: users editing the same .md in Obsidian/Files.app/Textastic while Notetaker's master list toggles checkboxes can collide. Mitigation relies on iCloud conflict versions + coordinated writes + durable task ids, but Markdown auto-merge is not safe and conflicts must be surfaced, not silently merged.
- iCloud Drive sync is eventually-consistent and chatty: half-downloaded files, .icloud placeholders, and delayed change notifications can produce transient index inconsistency; requires NSFileCoordinator + NSMetadataQuery download-state handling and debouncing, and a known 2025 macOS sandbox/FileProvider regression can drop folder access mid-session.
- SwiftData migrations remain fragile in 2026 for non-trivial/custom-stage transforms and lack first-class FTS — a reason the recommendation favors GRDB; if SwiftData is chosen anyway, complex schema evolution is a real breakage risk.
- CoreSpotlight is unsuitable as primary search (Apple's own 'few thousand items' guidance; weak ranking) — relying on it instead of FTS5 would degrade search at scale.
- Reusing the Python/Docling engine risks forcing Hardened Runtime exceptions (allow-jit / disable-library-validation) that weaken the notarized app; must be isolated in a helper to avoid degrading the main app's runtime, and untrusted documents pose decompression-bomb / malicious-embed risks.
- Locked-note passphrases have no recovery/key escrow (matching Apple) — a forgotten per-note passphrase means permanent data loss for that note; must be made unmistakably clear in UX.
- Homelab Ollama traffic leaves the device to the LAN/VPN; without TLS the endpoint and note contents could be exposed on the local network, and the iOS Local Network permission prompt adds onboarding friction.
- Shared notes/folders lose end-to-end encryption if any participant lacks ADP — a collaboration feature could silently downgrade the security posture of all participants.
- Embedding durable task ids as hidden markers in Markdown slightly pollutes the plain-text files and can be stripped by other editors, breaking master-list toggle targeting; needs a resilient fallback (fuzzy line re-matching on hash) when ids are lost.

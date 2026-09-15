# Spec 01 — Reading mode + the three-mode model

## Scope

### Mode model (app)

- `enum EditorMode: String, CaseIterable { case source, live, reading }`
  stored via `@AppStorage("editorMode")`, default `.live`. Lives in the App
  target (NotesView state) — packages stay unaware of "modes"; EditorKit
  keeps its `livePreview: Bool` parameter (source = false, live = true).
- **⌘E cycles** Source → Live → Reading → Source. **⌘/ toggles**
  Source ↔ Live (keeps today's behavior; from Reading it goes to Live).
- Format bar: replace the single eye/code toggle button with a compact
  three-segment picker (SF Symbols: `chevron.left.forwardslash.chevron.right`
  source, `eye` live, `book` reading — verify each symbol exists with
  `NSImage(systemSymbolName:)` before use; a nonexistent name renders blank).
  In Reading mode the formatting buttons are hidden (nothing to format);
  the note-action cluster (AI, lock, project, graph, focus, info) stays.
- Settings › Editor: "Default mode for notes" picker bound to the same key,
  plus "Source mode uses a monospaced font" toggle (`@AppStorage
  "sourceModeMonospace"`, default true) — Source is the "strict markdown"
  view; when on, pass a monospaced font design into the editor theme for
  source mode only.
- **Position survives switches**: Source↔Live share the text view (nothing
  to do). Live/Source → Reading: scroll the reading view so the block
  containing the caret's paragraph is at the top of the viewport. Reading →
  editor: place the caret at the start of the block the reading view had
  at the top (use the block's source line number).

### `Packages/ReadingKit` (new SwiftUI package; depends on MarkdownKit,
TaskEngine — NOT EditorKit)

Two layers so the structure is testable without UI:

1. **Render model** (pure, tested): `ReadingDocument.build(from source:
   String) -> [ReadingBlock]` walking the swift-markdown AST (via
   `Markdown.Document(parsing:)` — MarkdownKit already depends on
   swift-markdown) into an enum of blocks: heading(level, inlines),
   paragraph(inlines), list(ordered, items: [ListItem(inlines, checked:
   Bool?, sourceLine: Int, children)]), blockquote(blocks), codeBlock(lang,
   text), table(header, rows, alignments), thematicBreak, image(source, alt),
   frontmatter([(key, value)]), html-as-text fallback. Inlines: text, strong,
   emphasis, strikethrough, code, link(url), image, wikilink(target),
   highlight, tag, mention, kindToken, and — for task list items — the
   `TaskTokenParser` result (clean text + due/start/priority/labels/
   assignee/kind/recurrence) so tokens render as chips, never raw.
   Reuse `MarkdownStyler`'s extended-syntax detection or its regexes for
   wikilink/highlight/tag/mention/kind (do not invent new regexes).
   Every block carries its source line range (from `Markup.range`).
2. **Views**: `ReadingView(source:, style:, callbacks)` rendering the
   blocks: headings scaled by level; lists with proper nesting; task items
   as tappable circles (○/●) that call `onToggleTask(sourceLine)`; chips for
   priority/due/labels/assignee/kind using colors supplied by a
   `ReadingStyle` (the app maps `MarkdownTheme.tagColor`/`kindColor` into it
   so chips match the editor); wikilinks call `onOpenNote(title)`; http
   links open via `Link`; images resolve vault-relative paths against an
   `imageBase: URL?` and render capped like the editor (280pt); tables as a
   `Grid` with header row and alignment; code blocks monospaced in a card;
   blockquotes with an accent bar; frontmatter as a compact key/value card
   at the top; thematic break as a rule. `ScrollViewReader` ids per block
   (source line) for the position-sync API: `scrollTo(sourceLine:)` and
   `topVisibleSourceLine` reporting via a preference.

### App wiring (NotesView)

- Reading mode mounts `ReadingView` in place of `MarkdownEditor` inside the
  same in-content layout (header row stays; `.toolbar(.hidden)` stays).
- `onToggleTask(line)` → the existing task toggle path: find the
  `TaskRecord` for (selected note id, line) via `indexService` and call
  `service.toggle(task)` — the same outbound-write discipline as the To-Do
  tab (never mutate `noteText` directly). Reading view re-renders from the
  reloaded text.
- `onOpenNote(title)` → `model.openNote` by title lookup (same matching
  the editor's wikilink click uses — find it and reuse).
- `project.yml`: add the ReadingKit package to `packages` and to the app
  target's dependencies; `xcodegen generate`; commit both project.yml and
  nothing under the gitignored xcodeproj.

## Acceptance criteria

1. ReadingKit tests ≥ 15: block model for each block type, nesting, task
   item token extraction (chips not raw text), wikilink/highlight/tag
   detection parity with `MarkdownStyler` on a shared fixture, source-line
   mapping, frontmatter card model, a locked-note body (encrypted) rendering
   as a single "locked" placeholder rather than base64 soup.
2. Mode persists across launches; ⌘E cycles; ⌘/ toggles as before; the
   segmented picker reflects and sets the mode.
3. Switching Live→Reading→Live keeps the same paragraph in view (builder
   verifies by unit-testing the line↔block mapping and, if the app can be
   launched, by observation — report honestly which).
4. Reading mode: toggling a task checkbox flips the source line and the
   To-Do tab agrees (verify via the index after toggle in a test vault, or
   report as unverified-headless).
5. Existing EditorKit/MarkdownKit/TaskEngine tests untouched and green;
   macOS + iOS builds green; swiftformat lint clean on changed files.

## Files expected to change

- `Packages/ReadingKit/**` (new), `project.yml`
- `App/Notes/NotesView.swift` (mode state, picker, mount, callbacks)
- `App/Shell/SettingsView.swift` (Editor pane: default mode + source font)

## Non-goals

- Editing inside Reading view; footnotes; math; code syntax highlighting;
  per-note mode memory; split pane. Do not touch EditorKit's highlighter or
  layout fragments (specs 02/03 own them).

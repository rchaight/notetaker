# Notes rendering — plan overview (2026-09-15)

User direction (after research): the Notes editor's live preview is "not
perfect and clumsy." Research confirmed this is the documented failure mode
of the hide/reveal live-preview technique itself (Obsidian's forums are
full of the identical "lines shift, cursor jumps" complaint), not a
Notetaker-specific defect. No Swift package solves it; the web editors the
user named (editor.md — stale since 2024; Toast UI — archived; Milkdown /
Vditor / gravity-ui) are split-pane or WYSIWYG-over-HTML and contribute UX
ideas, not code. Renderers for a read-only view: MarkdownUI (maintenance
mode), Textual (active, unproven for custom tokens). Decision: **render
from the swift-markdown AST the app already parses**, no new dependency.

## What the code review found (the mechanics of "clumsy")

1. Off-caret markers hide via a 0.01pt font; caret entry snaps them to full
   size → the line's width/height changes → everything below reflows.
2. Every qualifying caret move re-parses the WHOLE note and re-applies
   attributes to the whole storage (`Coordinator.restyle` →
   `MarkdownStyler.styleRanges` + `MarkdownHighlighter.highlight`).
3. Tables flip between a drawn grid (caret outside) and raw pipes (inside).
4. Frontmatter collapses to a hairline off-caret and expands to a full
   block on entry — the biggest single jump.
5. Only two modes (live / source), toggled by ⌘/, not persisted, no true
   rendered read-only view.

## Decisions (user-selected)

- **Three modes**: Source / Live Preview / Reading. ⌘E cycles (Obsidian
  convention); ⌘/ keeps toggling Source↔Live. Mode is remembered globally
  (Obsidian's default; per-note memory is a follow-up if wanted). Caret /
  scroll position survives switches.
- **Reading view = own renderer** over the swift-markdown AST (MarkdownKit)
  + TaskEngine's `TaskTokenParser` for task lines — same parsers the editor
  uses, so chips/wikilinks/highlights never disagree between modes.
- **Live Preview hardening**: incremental restyle, Typora-style narrow
  reveal, tables stay a grid while editing, frontmatter as a properties card.

## Tasks

| # | spec | builder | files (overlap notes) |
|---|------|---------|------------------------|
| 01 | Reading mode + mode model | opus, worktree | new `Packages/ReadingKit`, `project.yml`, `NotesView.swift` (mode picker + mount), `SettingsView.swift` (default mode) |
| 02 | Live Preview core: incremental restyle + narrow reveal | opus, worktree | `MarkdownHighlighter.swift` (reveal path), `MarkdownEditor.swift` (restyle/selection path), `MarkdownKit/SyntaxMarkers.swift`, tests |
| 03 | Stable blocks: tables as a persistent grid + frontmatter card | opus, worktree | `TableRendering.swift`, new `FrontmatterLayoutFragment.swift`, `MarkdownHighlighter.swift` (table/frontmatter hiding branches ONLY), `MarkdownTheme.swift` |

02 and 03 both touch `MarkdownHighlighter.swift` in different branches of
`highlight(...)`; worktrees required, orchestrator merges 01 → 02 → 03 and
resolves, full gate after merge, fresh critic before push.

## Non-goals (all tasks)

- No WKWebView, no HTML document model, no third-party markdown renderer.
- No grammar changes; `TaskTokenParser` stays the one parser.
- Footnotes, math, syntax highlighting inside code blocks, per-note mode
  memory, side-by-side split pane (candidate follow-up once Reading exists).
- iOS: must keep building and keep current behavior; Reading mode and the
  mode picker should work on iOS where they compile cleanly (SwiftUI-only
  renderer makes this cheap), but macOS is the verification target.

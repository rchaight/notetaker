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

## Deferred follow-ups (from the post-merge critique, 3 rounds → pass, 2026-09-15)

1. Reading-mode checkbox on an unlocked locked note is a silent no-op (the
   index stores no task rows for `locked: true` notes); disable the circle
   or surface a hint when `model.selectedIsLockable`.
2. `applyRevealUpdate` and `restyle` each compute
   `livePreview ? RevealScope.at(…) : nil`; extract one `currentScope(for:)`
   helper per coordinator so the two sites cannot drift again.
3. `TableGrid.columnLayout` has no production caller now that the fragment
   stops re-drawing cell text — retire it or use it for true grid relayout.
4. `#tag` chips inside table cells take the uniform monospaced table font
   (columns stay aligned); color survives. Revisit if it reads oddly.
5. Toggling "Source mode uses a monospaced font" while already in Source
   mode repaints on the next restyle, not immediately (`modeChanged` watches
   livePreview/focusMode/baseFontSize, not fontDesign).
6. Frontmatter card rows render sorted by key (`Frontmatter.values` is a
   dictionary; file order is lost upstream).
7. In notes over the 20k-UTF16 debounce threshold, caret moves in the 150 ms
   after typing leave the reveal untouched until the debounced restyle lands.
8. Nothing in this feature set was observed live by anyone (builders declined
   to launch against the live vault): ⌘E cycling, the mode picker, ⌘F/⌘E/⌘/
   firing from the hidden button stack, Reading-mode checkbox toggles,
   position sync across mode switches, and the no-reflow feel are the user's
   shakedown checks.

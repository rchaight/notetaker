# Spec 03 — Stable blocks: tables stay a grid; frontmatter as a card

## Scope

Both changes remove a "the block changes shape when the caret enters it"
transition, using EditorKit's existing custom-layout-fragment machinery.

### A. Tables: one rendering in both states

Today: caret outside → pipes cleared and a grid drawn by `TableRow`
fragments (TableRendering.swift); caret inside → raw pipes. The flip is the
complaint. New behavior — the honest, buildable version (the text run must
stay editable in place, so cells are NOT relaid out into a true grid):

- Table lines always use the theme's **monospaced font**, so pipe columns
  line up whenever the table is aligned (the auto-align-on-leave from the
  table-editing pass keeps it aligned; `TableEditing.align` exists).
- Pipes are always drawn as **light column separators** (dimmed color at
  full size — never 0.01pt, never cleared) and the fragment draws the row
  rules and header emphasis in BOTH states. The separator row (`| --- |`)
  renders as the header underline in both states (its dashes dimmed, not
  hidden, so its height is stable).
- Entering a table therefore changes nothing visually except the caret
  appearing; leaving triggers the existing align pass.
- Source mode (livePreview = false): no grid drawing, plain pipes.
- Remove the `.table` "clear the whole range" branch in
  `MarkdownHighlighter.highlight` and replace it with the dimmed-separator
  attributes; keep `TableGrid.regions` (spec 02 and the key tests use it).

### B. Frontmatter: a properties card, no hairline collapse

Today the frontmatter block collapses to 0.01pt off-caret and expands on
entry. New:

- Off-caret: the block keeps its **line count and line height** (no
  reflow) but renders as a card: a `FrontmatterLayoutFragment` draws a
  rounded background across the block's lines, each `key: value` line
  styled small/monospaced/secondary, the `---` fences dimmed (not hidden).
- Caret inside: same font metrics; the card background stays; the fences
  and text go to normal secondary color so it reads as editable. No size
  change on entry or exit — that is the acceptance criterion.
- `MarkdownDocument.bodyUTF16Offset` still defines the block. Notes with
  no frontmatter are unaffected. Locked notes (`locked: true`) show the
  card for the frontmatter lines only; the encrypted body is untouched.
- Theme: add `frontmatterAttributes` / card colors to `MarkdownTheme` next
  to `hiddenMarkerAttributes`.

## Acceptance criteria

1. Highlighter tests: (a) table ranges carry the monospaced font and
   dimmed-pipe attributes with the caret inside AND outside — identical
   attribute runs; (b) frontmatter lines carry identical font size inside
   and outside, only color differs; (c) source mode leaves both plain.
   ≥ 8 tests.
2. Layout test with a live NSTextView (pattern: `TableEditorKeyTests`):
   measure the layout height of a 3-row table and of a 3-line frontmatter
   block with the caret outside, then inside — heights equal.
3. Existing EditorKit tests green (≥ 143), especially TableEditorKeyTests
   (Tab navigation must still work — the text under the grid is unchanged).
4. macOS + iOS builds green; swiftformat lint clean on changed files.
5. Manual check if launchable: click into a table and into frontmatter —
   nothing moves; report honestly what was observed.

## Files expected to change

- `Packages/EditorKit/Sources/EditorKit/TableRendering.swift`
- `Packages/EditorKit/Sources/EditorKit/FrontmatterLayoutFragment.swift` (new)
- `Packages/EditorKit/Sources/EditorKit/MarkdownHighlighter.swift` — ONLY
  the `.table` branch and the frontmatter branch inside `highlight`; do not
  restructure the marker-hiding loop (spec 02 rewrites it)
- `Packages/EditorKit/Sources/EditorKit/MarkdownTheme.swift`
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditor.swift` — ONLY where
  the layout-fragment delegate chooses a fragment class (add the
  frontmatter fragment); nothing else in that file
- EditorKit tests (new file)

## Non-goals

- True grid relayout of cells; column resizing by mouse; frontmatter key
  editing UI; Reading mode's table/frontmatter rendering (spec 01 owns its
  own views).

# Spec 02 — Live Preview core: incremental restyle + narrow reveal

## Scope

Two changes to how EditorKit's live preview responds to the caret. Both are
about the same code path (`MarkdownHighlighter.highlight` +
`Coordinator.restyle` / `textViewDidChangeSelection`), so one builder.

### A. Incremental restyle — caret moves never re-parse

Today `restyle(_:)` runs `MarkdownStyler.styleRanges` over the whole note
and re-applies every attribute to the whole storage on any caret move that
crosses hidden content. The parse cannot change when only the caret moved.

- Cache the last full parse (`currentStyledRanges`, plus the derived
  marker/reveal ranges, fold ranges, regions) keyed by the text it came
  from. On **caret-only** changes: no parse; compute the old and new reveal
  scopes; re-apply attributes ONLY within the paragraphs (or spans) whose
  visibility changed — via a new `MarkdownHighlighter.updateReveal(storage,
  theme:, styled:, from: oldScope, to: newScope, foldRanges:)` that
  restores hidden-marker attributes on the ranges leaving reveal and
  re-applies base styling + reveal on ranges entering it. Wrap in one
  `beginEditing`/`endEditing` over the union of affected ranges only.
- Text changes keep the full parse, but the full attribute re-application
  may stay (it's already debounced for long notes). Optional stretch:
  paragraph-scoped re-application when the edit stays within one paragraph
  and the parse's block structure outside it is unchanged.
- The equivalence invariant, TESTED: for any text, caret A, caret B,
  `full restyle at B` produces attributes identical to `full restyle at A`
  followed by `updateReveal(A→B)`. Property-style test over the existing
  highlighter fixtures (headings, bold/italic/code spans, lists, quotes,
  tables, frontmatter, folded headings) comparing attribute runs.

### B. Narrow reveal (Typora-style)

Replace the paragraph-wide `hideMarkersOutside: NSRange` with a
`RevealScope`:

- **Block markers** of the caret's line reveal: heading `#`s, list bullet /
  number, blockquote `>`, task `[ ]` token, table pipes (subject to spec 03
  — pipes stay rendered as separators; do not fight it: in this spec treat
  table lines as "no reveal change", spec 03 owns their look).
- **Inline markers** reveal only for the styled span(s) that contain or
  touch the caret: `**`, `*`/`_`, `` ` ``, `~~`, `==`, `[[ ]]`, `[text](url)`
  syntax, `![alt](src)`. A caret in plain text between two bold spans
  reveals neither. Selections: every span intersecting the selection.
- Frontmatter and fold behavior unchanged here (spec 03 owns frontmatter).
- `SyntaxMarkers.markerRanges(in:styled:)` (MarkdownKit) likely needs to
  return markers grouped by owning span so the scope can be computed —
  extend it (keep the existing function for callers).
- Reflow honesty: a revealed span still changes width. Keep the existing
  `cursorTransitionAffectsLayout` gate (now per-span, so far fewer moves
  trigger any layout at all) — that is the win.

## Acceptance criteria

1. Equivalence property test (A→B incremental == full at B) green across
   the fixture set; ≥ 8 narrow-reveal tests (caret in bold span reveals
   only that `**` pair; caret on a heading line reveals `#`; caret in plain
   text between spans reveals nothing; selection across two spans reveals
   both; caret entering a link reveals `[](…)`; code span; strikethrough;
   list line bullet + inline span together).
2. No `MarkdownStyler.styleRanges` call on a caret-only change (assert via a
   counting hook or a test double on the highlighter path).
3. All existing EditorKit tests green (≥ 143), including the table key
   tests, the stale-region regression, and the fold tests.
4. macOS + iOS builds green; swiftformat lint clean on changed files.
5. Manual check if the app can be launched: click around a long note —
   no visible shift except the span under the caret; report honestly.

## Files expected to change

- `Packages/EditorKit/Sources/EditorKit/MarkdownHighlighter.swift`
  (reveal scope + `updateReveal`; leave the table-clear and frontmatter
  branches structurally alone — spec 03 edits those)
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditor.swift`
  (`restyle`, `textViewDidChangeSelection`, `cursorTransitionAffectsLayout`;
  do not touch view creation, `doCommandBy`, paste, or the selection-context
  publish call — keep those lines as they are)
- `Packages/MarkdownKit/Sources/MarkdownKit/SyntaxMarkers.swift` (+ tests)
- EditorKit tests (new file for the new tests; extend HighlighterTests only
  where the assertions must change)

## Non-goals

- Table or frontmatter rendering (spec 03). Reading mode (spec 01).
- Any change to what is written to disk.

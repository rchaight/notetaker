# Spec 01 — Table editing UX (Tab navigation, row/column commands, auto-align)

## Scope

Make pipe tables feel structurally editable instead of raw text. Build on
what exists: `TableGrid.regions(in:styled:)` in
`Packages/EditorKit/Sources/EditorKit/TableRendering.swift` already parses
regions → rows → cells with UTF-16 ranges; the grid renders when the cursor
is outside, raw pipes when inside; the macOS Coordinator already intercepts
`doCommandBy` (MarkdownEditor.swift:543).

### Pure logic: `TableEditing` (new file in EditorKit, fully unit-tested)

Given the note text, its `[StyledRange]`, and a cursor location:

- `cellAt(location:)` → (region, rowIndex, colIndex, contentRange) — content
  range excludes the pipes and one padding space each side when present.
- `nextCell` / `previousCell` targets: Tab order is left-to-right, top-to-
  bottom, skipping the `---` separator row. Tab in the LAST cell appends a
  new empty row and targets its first cell. Shift-Tab in the first cell stays.
- `insertRow(afterRow:)`, `insertColumn(afterCol:)`, `deleteRow(_:)`,
  `deleteColumn(_:)` → `EditResult` (range/replacement/selection, same shape
  `MarkdownEditing.apply` returns). Deleting the last data row deletes the
  table; deleting the last column deletes the table. Header and separator
  rows stay structurally valid after every operation.
- `aligned(region:)` → replacement text with every column padded to its
  widest cell (min width 3) and the separator row rebuilt (`---`, preserving
  `:` alignment markers if present). Must be idempotent.

### Editor integration (macOS Coordinator)

- In `doCommandBy`: `insertTab:` / `insertBacktab:` when the selection is
  inside a table region → select the next/previous cell's content and return
  true. `insertNewline:` inside a table → insert a row below the current one
  and select its first cell. Outside tables, existing behavior untouched
  (the list-continuation newline handling at ~line 721 must keep working —
  a table row is never also a list line, but prove it with the existing
  tests still green).
- **Auto-align on leave:** track the table region containing the cursor; on
  selection change, when the cursor leaves a region that was modified while
  inside, replace it with `aligned(region:)` output (one undo group,
  selection preserved). Never rewrite while the cursor is inside the table.
- iOS: no key interception this pass; the row/column commands below work
  there via the shared command path.

### Commands + format bar

- New `EditorCommand` cases in MarkdownEditing.swift: `.tableInsertRow`,
  `.tableInsertColumn`, `.tableDeleteRow`, `.tableDeleteColumn`,
  `.tableAlign` — applied via `MarkdownEditing.apply` using `TableEditing`;
  ALL are safe no-ops when the selection is not inside a table.
- `NotesView.swift` format bar: extend the existing `plus.square` Menu
  (~line 650) with a "Table" submenu-style group: Add Row Below, Add Column
  After, Delete Row, Delete Column, Align Table — always enabled (no-op
  outside tables), each sending its command via `editorCommand`.

## Acceptance criteria

1. EditorKit tests for `TableEditing`: ≥12 cases — cell resolution at edges
   (first/last cell, separator row, cursor on a pipe), Tab/Shift-Tab
   ordering, Tab-in-last-cell row creation, insert/delete row+column
   including last-row/last-column table deletion, `aligned` idempotence and
   `:` alignment preservation.
2. Existing EditorKit tests all still pass (69 currently).
3. Manual check in the built app (report what you observed): type a 2×2
   table, Tab through cells, Enter adds a row, leave the table → pipes align,
   undo restores, the grid still renders when the cursor is outside.
4. macOS + iOS builds green; `swiftformat --lint` clean on changed files.

## Files expected to change

- `Packages/EditorKit/Sources/EditorKit/TableEditing.swift` (new) + new test file
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditing.swift` (new commands)
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditor.swift` (doCommandBy +
  selection-leave hook ONLY — stay out of view creation and the
  selection-context work other specs own)
- `App/Notes/NotesView.swift` (insert-menu items ONLY)

## Non-goals

- No mouse/hover chrome on the rendered grid (later pass if wanted).
- No column-alignment UI beyond preserving existing `:` markers.
- No changes to TableGrid parsing or the fragment rendering.

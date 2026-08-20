# Spec 03 — Selection-aware format bar, link editing, image polish

## Scope

The format bar should reflect where the cursor is (like every WYSIWYG);
⇧⌘K should EDIT an existing link, not just insert; images deserve sane
inline sizing and click-to-open.

### `SelectionContext` (pure computation in EditorKit, unit-tested)

New file. From the note text, its `[StyledRange]`, and the selected range:

```swift
public struct SelectionContext: Equatable, Sendable {
    public var bold, italic, strikethrough, code: Bool
    public var headingLevel: Int      // 0 = body
    public var inCodeBlock, inTable, inList, inQuote: Bool
    public var link: (range: NSRange, destination: String)?  // caret inside a link
}
```

A style counts as active when the caret sits inside (or the selection is
fully covered by) a range of that kind. Computed by a static
`SelectionContext.at(_ selection: NSRange, ranges: [StyledRange])`.

### Editor → app plumbing

- macOS Coordinator: on selection change (the existing
  `textViewDidChangeSelection` path, MarkdownEditor.swift ~451/522 region),
  compute `SelectionContext` from the coordinator's current style ranges and
  publish through a new optional callback
  `onSelectionContext: ((SelectionContext) -> Void)?` on the editor view.
  Reuse ranges already computed for styling — do NOT re-parse the document
  on every caret move; skip publishing when the context is unchanged.
- iOS: same callback from the UITextView delegate's selection change if
  cheap; otherwise leave nil (bar state is macOS-first).

### Format bar (NotesView.swift — buttons/styling ONLY, not the insert menu)

- Highlight active states: bold/italic/strikethrough/code buttons get a
  `.selection`-style capsule background when active (same visual language as
  the top tab bar); heading menu label shows the current level ("H2" etc.)
  and the menu checkmarks it; list/quote buttons highlight from
  inList/inQuote.
- While `inCodeBlock`, wrap-style buttons are disabled (visually dimmed) —
  markdown syntax is inert there anyway.

### Link editing

- `MarkdownEditing`: extend the `.link` command path (or add `.editLink`)
  so that when `SelectionContext.link` is present the command targets the
  EXISTING link's text/destination instead of inserting a placeholder.
- NotesView: ⇧⌘K with caret in a link opens a small popover anchored to the
  format bar's link button: text field + URL field + Save/Remove Link.
  Save rewrites `[text](url)` via the editor-command path; Remove unwraps to
  plain text. With no link at the caret, current insert behavior stays.
- Clicking links already opens them (Coordinator clickedOnLink:706) — keep.

### Image polish

- `ImageLayoutFragment`: cap rendered height (~280pt) preserving aspect,
  max-width = text container width, subtle rounded corners; alt text/domain
  caption only if already present (don't add new chrome).
- Click (macOS) on a rendered image fragment opens the underlying file:
  editor exposes `onOpenAttachment: ((String) -> Void)?` with the image
  source path; NotesView wires it to `NSWorkspace.shared.open` resolving
  vault-relative paths against the vault root (remote URLs → open URL).
  iOS: tap does nothing new this pass.

## Acceptance criteria

1. EditorKit tests ≥8 for `SelectionContext.at`: caret in bold, in nested
   bold+italic, heading levels, code block suppression, link detection with
   destination, table/list/quote flags, plain-text all-false case.
2. Existing EditorKit tests still green.
3. Manual checks in the built app (report observations): caret into bold
   text lights the B button; heading menu reads the level; ⇧⌘K inside an
   existing link pre-fills the popover and Save rewrites it, Remove unwraps;
   a large image renders capped with aspect preserved; clicking it opens
   the file.
4. macOS + iOS builds green; `swiftformat --lint` clean on changed files.

## Files expected to change

- `Packages/EditorKit/Sources/EditorKit/SelectionContext.swift` (new) + new test file
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditor.swift` (selection-
  change region + callbacks ONLY — stay out of doCommandBy and view-creation
  regions other specs own)
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditing.swift` (link edit —
  coordinate: spec 01 also edits this file adding table commands; keep your
  change to the link section only)
- `Packages/EditorKit/Sources/EditorKit/ImageLayoutFragment.swift`
- `App/Notes/NotesView.swift` (format-bar button styling + link popover +
  attachment-open wiring ONLY — not the insert menu, not editor closure
  wiring beyond onOpenAttachment/onSelectionContext)

## Non-goals

- No floating inline formatting bar / context toolbar.
- No image resize handles or size persistence in markdown.
- No link preview cards.

# Spec 02 — Rich paste + drag-and-drop (HTML/RTF → markdown, images, URL links)

## Scope

Pasting from browsers/Word/Mail should produce clean markdown; pasting a URL
over selected text should make a link; images should paste/drop straight
into the note.

### Converter: `RichPaste` (new file in EditorKit, unit-tested)

- `markdown(fromAttributed: NSAttributedString) -> String` — walks runs and
  paragraphs to emit markdown: bold/italic (font traits), strikethrough,
  links, headings (font size tiers relative to body), bulleted/numbered
  lists (NSParagraphStyle textLists or leading marker text), inline code /
  code blocks (monospaced font runs), blockquotes where detectable,
  plain paragraphs separated by blank lines. Unknown styling degrades to
  plain text — NEVER drop text content. Tables inside pasted HTML may
  degrade to plain lines (non-goal to reconstruct pipe tables).
- The HTML/RTF → NSAttributedString step happens at the call site with the
  standard `NSAttributedString(data:options:documentType:)` importers
  (`.html` import runs on the main thread — the paste path already is).
- `isProbablyMarkdown(_ plain: String) -> Bool` heuristic (headings, `- `
  lists, fenced code, pipes, `[]()` links) — used to prefer the PLAIN
  pasteboard string when the source text already looks like markdown.
- `linkWrapping(selection: String, pasted: String) -> String?` — returns
  `[selection](url)` when `pasted` is a single http(s) URL and the selection
  is non-empty and not itself a URL; nil otherwise.

### Text-view subclasses (this spec owns view creation in MarkdownEditor.swift)

- macOS: new `MarkdownTextView: NSTextView` overriding `paste(_:)` and the
  drag-and-drop methods; created wherever the editor currently builds its
  `NSTextView` (MarkdownEditor.swift makeNSView ~line 93–130, and the
  SharedEditorCache path — the cached view must be the subclass).
  "Paste and Match Style" (`pasteAsPlainText:`) must keep pasting the raw
  plain string unmodified — that's the user's escape hatch.
- iOS: `MarkdownUITextView: UITextView` overriding `paste(_:)` with the same
  decision ladder (UIPasteboard); created at ~line 775.
- Decision ladder for paste (first match wins):
  1. Pasteboard has image data or image-file URLs → import (below).
  2. Plain string is a lone URL and selection is non-empty → `linkWrapping`.
  3. Plain string exists and `isProbablyMarkdown` → default paste (plain).
  4. HTML or RTF flavor present → import to NSAttributedString → converter →
     insert markdown (one undo group). On ANY conversion failure → default
     plain paste. Never lose a paste.
  5. Otherwise → default paste.

### Image import path

- Editor exposes a closure (nil = feature off, default):
  `importAttachments: (([AttachmentDrop]) async -> [String])?` where
  `AttachmentDrop` is file URL or raw data + suggested name, and the return
  is vault-relative markdown paths.
- Paste/drop of images calls it and inserts `![<name>](<path>)` per image
  (own paragraphs), at the caret (paste) or drop point.
- App side: `NotesModel.attachImage(from: URL)` already exists
  (NotesModel.swift:516, copies into `Attachments/` via VaultNaming);
  add a `attachImage(data:suggestedName:)` variant writing through the same
  coordinated path, and wire the closure in `NotesView` where the editor is
  constructed (the fileImporter flow at NotesView.swift:~669 shows the
  existing pattern: attach → insertBlock).
- Drag sessions that contain non-image files: ignore (leave to any existing
  behavior); never write non-image data into Attachments.

## Acceptance criteria

1. EditorKit tests ≥10: converter cases (bold/italic/link/heading/list/code
   fixtures built as attributed strings, content-never-lost degenerate case),
   `isProbablyMarkdown` positives/negatives, `linkWrapping` (url over text,
   url over url, non-url paste, empty selection).
2. Existing EditorKit tests still green.
3. Manual checks in the built app (report observations): copy a formatted
   web page snippet → paste gives markdown; paste same with Paste-and-Match-
   Style gives plain text; copy markdown from another editor → pastes
   verbatim; paste URL over a selected word → link; paste a screenshot
   (⌃⇧⌘4 to clipboard) → file appears in `Attachments/`, `![...]` inserted,
   image renders; drag an image file from Finder → same.
4. macOS + iOS builds green; `swiftformat --lint` clean on changed files.

## Files expected to change

- `Packages/EditorKit/Sources/EditorKit/RichPaste.swift` (new) + new test file
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditor.swift` (view creation /
  subclass introduction ONLY — stay out of doCommandBy and selection-change
  regions other specs own)
- `App/Notes/NotesModel.swift` (data-variant attachImage)
- `App/Notes/NotesView.swift` (closure wiring ONLY — not the format bar)

## Non-goals

- Reconstructing pipe tables from pasted HTML tables.
- Non-image attachments (PDF etc.).
- Paste customization settings UI.

# 06 — Wikilinks clickable in Source and Live modes

## Goal

⌘-click on a `[[link]]` in the editor opens the target note (with heading/block anchors), exactly as a tap does in Reading mode, through the one resolver from spec 05. An unresolved target offers to create the note. Plain clicks, drags and selection are untouched.

## Verified findings

- The editor styles wikilinks (`MarkdownTheme.swift:269-271`, accent + underline) but attaches no `.link` attribute to them; the only `.link` in the highlighter is the checkbox toggle URL (`MarkdownHighlighter.swift:277`), handled by `textView(_:clickedOnLink:at:)` (`MarkdownEditor.swift:1090-1109`). So a click on a wikilink just places the caret. Plan claim correct.
- Proven click-interception pattern in this editor: `NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown)` for margin folds (`:452-470`) and image thumbnails (`:856-883`), because NSTextView's `mouseDown` tracking loop swallows gesture recognisers. Monitors are removed in the same lifecycle as `foldClickMonitor` (`:456`).
- Reading mode routes taps through a private URL scheme to `onOpenNote` (`ReadingInlineText.swift:11-27`, `ReadingView.swift:122-129`) into `NotesView.openWikilink` (`:1518-1525`), which does an exact case-insensitive title match and silently does nothing on a miss.
- The "reading-mode toggle drift guard" in the plan is `toggleReadingTask` (`NotesView.swift:1503-1516`): it refuses a checkbox toggle when the index line no longer equals the rendered line. Link opening never writes, so it has no drift to guard; this spec does not touch that function.
- Cross-tab jump exists: `NotesModel.openNote(_:jumpToLine:)` + `consumeJumpLine` consumed in `NotesView` `.onChange(of: model.noteText)` (`:639-645`) once the text is loaded.
- `NotesModel.createNote(in:)` (`:790-816`) always names the note "Untitled"; a titled variant is needed.

## Design

### EditorKit (group B)

- `Sources/EditorKit/WikilinkHitTest.swift` (new, pure): `enum WikilinkHitTest { static func link(at index: Int, in text: String) -> Wikilink? }` — takes the paragraph containing `index` (`NSString.paragraphRange(for:)`), runs `WikilinkSyntax.links(in: paragraph)` and returns the link whose `range` (shifted by the paragraph start) contains `index`, with `range`/`targetRange` shifted to full-text coordinates. No code exclusion (a ⌘-click on `[[x]]` inside a code span opening a note is harmless; keeping it paragraph-local keeps the click free).
- `MarkdownEditor` (both platform structs, for call-site parity) gains `onOpenWikilink: ((Wikilink) -> Void)? = nil` after `onOpenAttachment`. macOS coordinator: `installWikilinkClickMonitorIfNeeded(for:)` mirroring `installImageClickMonitorIfNeeded` (`:856-868`): on `.leftMouseDown` with `event.modifierFlags.contains(.command)` and `event.window === textView.window`, convert the point, require `textView.bounds.contains(point)`, `let index = textView.characterIndexForInsertion(at: point)`, `WikilinkHitTest.link(at: index, in: textView.string)` → call `onOpenWikilink(link)` and return `nil` (swallow, so the caret does not move and no discontiguous-selection gesture starts); otherwise return the event. Install next to the image monitor; remove with it. iOS: parameter stored, unused (Phase 3).
- Works identically in Source and Live: hidden syntax markers keep their characters, so `characterIndexForInsertion` lands inside the link's range either way.

### App (group C3, after spec 05's `NotesModel.rename` lands in the same file)

- `NotesView.openWikilink(_:)` is replaced by `openWikilink(_ link: Wikilink)`: `WikilinkSyntax.resolve(link, among: model.notes.map { ($0.id, noteTitle($0)) }, from: model.selectedID)`; hit → `model.openNote(id, jumpToAnchor: (link.heading, link.blockId))`; miss and `link.target.isEmpty` (`[[#Heading]]`) → jump within the current note; miss otherwise → `createLinkCandidate = link` driving a `confirmationDialog("Create “\(link.title)”?")` with "Create Note" → `model.createNote(titled: link.title, in: folder(of: model.selectedID))` then open it. Reading mode's `onOpenNote` now hands over the raw inner text (spec 05) → `WikilinkSyntax.links(in: "[[\(raw)]]").first` → the same function. The editor gets `onOpenWikilink: { openWikilink($0) }`.
- `NotesModel`: `openNote(_ id: String, jumpToAnchor: (heading: String?, blockId: String?)?)` stores `pendingJumpAnchor`; `consumeJumpAnchor()`; in `NotesView`'s `.onChange(of: model.noteText)` (`:639-645`) resolve `pendingJumpLine ?? WikilinkSyntax.anchorLine(heading:blockId:in: model.noteText)` into the `scrollTarget` offset as today. `createNote(titled:in:)`: generalise `createNote(in:)` with a `title` parameter (default "Untitled"), sanitised with `sanitizeFileName`, uniquified as today, body `# \(title)\n\n`; the old signature stays as a wrapper.
- Reading mode anchors: `scrollToLine` already exists (`readingScrollLine`); when the opened note lands in Reading mode set `readingScrollLine` from the same anchor line.

## Acceptance criteria

1. Source and Live: ⌘-click anywhere inside `[[Plan 2026]]` opens it; ⌘-click on plain text does what it did before (nothing special); plain click/drag/shift-click select as before; double-click selects a word inside a link.
2. `[[Plan 2026#Budget]]` lands with the caret on the "Budget" heading line; `[[Plan 2026#^abc12]]` on the line ending `^abc12`; a missing anchor opens at the top.
3. `[[Nope]]` → dialog; Create makes `Nope.md` in the current note's folder, opens it, and the link in the source now resolves (no edit to the source).
4. `[[Plan 2026|see]]` and `[[Projects/Plan 2026]]` open the right note from both the editor and Reading mode.
5. Checkbox clicks, heading-fold margin clicks and image clicks still work in the same note.

## Files expected to change

Group B: `Packages/EditorKit/Sources/EditorKit/{WikilinkHitTest.swift (new), MarkdownEditor.swift}`, `Packages/EditorKit/Tests/EditorKitTests/WikilinkHitTestTests.swift` (new).
Group C3: `App/Notes/{NotesModel.swift, NotesView.swift}`.
Must NOT touch: `MarkdownHighlighter.swift` (no `.link` attribute for wikilinks — plain click must keep placing the caret), `ReadingKit` (done in spec 05), `GraphView.swift`.

## Tests (EditorKit, Swift Testing)

`WikilinkHitTestTests`: `hitInsideBracketsReturnsLink`, `hitOnBracketCharacterCounts`, `hitOutsideReturnsNil`, `hitUsesParagraphLocalScanWithFullTextRanges` (multi-paragraph text, link on line 3: returned `range.location` is the full-text offset), `aliasAndHeadingSurvive`. Resolution/anchor logic is tested in MarkdownKit (spec 05). The monitor itself is AppKit-only and covered by the manual checklist.

## Regression guard

- `installFoldClickMonitor` and the image monitor keep their behaviour; monitors are removed on dismantle (no leaks: open/close 20 notes, no duplicate opens).
- Autocomplete for `[[` (`MarkdownEditor.swift:545-600`) untouched.
- Reading mode `toggleReadingTask` drift guard untouched; Reading taps on wikilinks still open notes.
- `openNote(_:jumpToLine:)` callers (To-Do, Meetings, Tags, Task window: `AppShell.swift:208-211, 225-228, 240-245`, `NotetakerApp.swift:69-71`) unchanged.

## Non-goals

Plain-click following in Live mode (Obsidian-style); hover cursor/underline-on-⌘; keyboard "follow link" (⌘↩); opening in a new tab/window; link previews; iOS tap-to-follow in the editor (Phase 3); rendering embeds `![[…]]`; back/forward navigation history.

## Builder model

EditorKit half: sonnet. App half: part of group C3 (opus), because it shares `NotesModel`/`NotesView` edits with spec 05 and the anchor jump rides the same selection path as rename's retargeting.

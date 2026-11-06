# 04 — Editor header, option (c): title row + tool row (macOS only)

## Goal

The note pane gets a title row and one tool row with a ⋯ overflow, a text-labelled mode picker, a single opaque surface tone, and a text column capped at 780 pt. Every control in today's chrome keeps a home. iPhone chrome is untouched (Phase 3).

## Hard constraints (from CLAUDE.md)

Header built in-content: plain `VStack`, opaque `Color.headerBackground` (`MeetingsView.swift:465-474`), `Divider()`, no translucent material, no `.safeAreaInset`, no `.toolbar`, no `.navigationTitle`, no `.inspector`. The window toolbar stays as it is.

## Verified findings

- The plan says the mockup for (c) is in the plan file; it is not (the plan notes mockups were in the questions to Robert). This spec designs from the option text: "title row + one tool row with ⋯ overflow, text mode picker, one surface tone, 780 pt line cap".
- Current chrome is shared by macOS and iOS (no `#if` around `editorHeader`, `NotesView.swift:816-829`); only the `.navigationTitle` at `:1362-1365` is iOS-only. So "iPhone untouched" means the new header is `#if os(macOS)` and the current one moves to the `#else` branch.
- The format bar's background is `.bar` (`:959`) — a material, i.e. translucent — while the header is `Color.headerBackground` (`:828`): two tones today.
- Reading mode already caps the column at 780 pt (`ReadingView.swift:110` `.frame(maxWidth: 780)`). The editor does not: `textContainerInset = 16×16`, `widthTracksTextView = true` (`MarkdownEditor.swift:166-178`). The image and fold hit tests subtract `textContainerInset` (`:870-873`), so a larger inset keeps them correct.
- Inventory of current controls (all `App/Notes/NotesView.swift`):

| control | lines | new home |
|---|---|---|
| tab strip (open notes, ✕) | `:1225-1261`, shown at `:779-781` | unchanged, above the title row |
| mode picker (segmented icons, ⌘E/⌘/ help) | `:833-845` | tool row, right, **text labels** |
| daily note ◀ ▶ | `:850-861` | title row, right of the title, only for daily notes |
| AI menu: Summarize, Extract Action Items, status line | `:862-883` | ⋯ menu |
| Proofread ⇧⌘P (editing modes, LT configured) | `:886-897` | ⋯ menu |
| Lock / Remove lock | `:898-914` | ⋯ menu |
| Project flag toggle | `:915-927` | ⋯ menu |
| Link graph | `:928-930` | ⋯ menu |
| Focus mode toggle | `:931-936` | ⋯ menu (checkmark) |
| Inspector ⌥⌘0 | `:937-940` | ⋯ menu (checkmark) |
| format bar scroll + `.bar` | `:945-960` | tool row, left (same `formattingControls`), no material |
| Heading menu, Bold, Italic, Strike, Code, lists, To-do, Quote, Link, Insert menu (+ image importer) | `:962-1072` | unchanged inside `formattingControls` |
| hidden shortcut buttons | `:1327-1345` | removed by spec 01 |
| stats chip (glass capsule overlay) | `:1346-1354` | unchanged (floats over text) |
| locked placeholder (no header) | `:1264-1277` | unchanged |
| editor frame `minWidth 380, idealWidth 720` | `:787` | unchanged |

## Design

### Layout (macOS branch of `editorPane`)

```
VStack(spacing: 0) {
    titleRow        // HStack: Text(selectedTitle).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    //        Spacer(); [◀ ▶ when model.openDailyNoteDate != nil]; overflowMenu
                    // .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    toolRow         // HStack: formatBar (ScrollView, formattingControls when editorMode.isEditing, else EmptyView keeping height 32)
                    //        Spacer(minLength: 8); modePicker
                    // .padding(.horizontal, 10).padding(.vertical, 4)
}
.background(Color.headerBackground)
Divider()
[ReadingView | MarkdownEditor]   // as today
```

- `formatBar` loses `.background(.bar)`; the header block has the one tone. The `.buttonStyle(.borderless)` and paddings stay.
- `modePicker`: `Picker` segmented, `Text(mode.shortTitle)` per case in `EditorMode.allCases` order (Source · Live · Reading), `.labelsHidden()`, fixed width 220, same `.help`. Add `public var shortTitle: String` to `EditorMode` (`EditorKit/EditorMode.swift`: "Source", "Live", "Reading"); `title` keeps "Live Preview" for Settings.
- `overflowMenu`: `Menu { … } label: { Image(systemName: "ellipsis.circle") }` with `.menuIndicator(.hidden)`, `.buttonStyle(.plain)`, same icon sizing as `actionIcon` (`:438-450`). Items in order, each calling the **same action closures the removed buttons used** (factor them into private funcs so spec 01's bus dispatch and this menu share them): Rename… (added by spec 05; omit until then), Proofread… (⇧⌘P label via `.keyboardShortcut` is **not** attached here — shortcuts belong to the menu bar; show the key in the title text only if spec 01 shipped the AppKit fallback), Summarize Note, Extract Action Items, `Text(aiStatus)` when non-nil, —, Lock Note / Remove Lock, Make Project / Remove Project Flag, —, Focus Mode (✓ when on), Show Inspector (✓ when on), Link Graph…, —, Move to Trash… (`trashCandidate = notesById[selectedID]`). Disable rules identical to the old buttons (`:886`, `:898`, `:915`).
- Title row text is the file name (`selectedTitle`, `:2245-2247`). `onTapGesture(count: 2)` → opens Rename (spec 05); until then no gesture.
- Mode switching still goes through `setMode` (`:1380-1395`) so the Reading↔editor scroll hand-off is kept.

### 780 pt text column (EditorKit)

`MarkdownEditor` gains `maxTextWidth: CGFloat? = nil` (both platform structs, for call-site parity; iOS ignores it this pass). macOS: `MarkdownTextView` gets `public var maxTextWidth: CGFloat?` and overrides `setFrameSize(_:)`: after `super`, `textContainerInset = NSSize(width: Self.horizontalInset(viewWidth: frame.width, maxTextWidth: maxTextWidth), height: 16)`, where `static func horizontalInset(viewWidth: CGFloat, maxTextWidth: CGFloat?) -> CGFloat` returns `max(16, (viewWidth - max)/2)` rounded down, or 16 when nil. `widthTracksTextView` keeps the container width = frame − 2·inset, so wrapping follows. `NotesView` passes `maxTextWidth: 780` on macOS. The fold-click margin test and image hit test already use the inset. Check `RevealScopeTests`/`StableBlockTests` still pass (they do not depend on the inset).

### iOS

`#else` branch keeps today's `editorHeader` verbatim (rename it `legacyEditorHeader` only if the compiler needs distinct names). `formattingControls`, `formatButton`, `headingMenuItem`, `linkButton`, `noteActionBar`, `modePicker` stay shared helpers; `noteActionBar` and the icon `modePicker` become iOS-only at the call site (wrap their definitions in `#if !os(macOS)` only if they become unused on macOS and the compiler warns).

## Acceptance criteria

1. Mac: the header is two rows on one opaque tone; no `.bar`/material in the note pane except the stats chip; resizing the window never shows text under the header.
2. Every inventory row is reachable; the ⋯ items enable/disable exactly as the buttons did; Reading mode hides the format cluster but keeps the row height (no jump).
3. Window 1400 pt wide: editor text wraps at ≤ 780 pt and is centred; at 700 pt the inset is 16 pt. Reading mode's column matches within ±16 pt.
4. Clicking in the side gutters still focuses the editor and places the caret at the line's end (the gutter is inside the text view).
5. iPhone: editor chrome pixel-identical to Phase 1 (icon picker, action bar). The iOS build compiles with `maxTextWidth` ignored.

## Files expected to change

`App/Notes/NotesView.swift`, `Packages/EditorKit/Sources/EditorKit/{EditorMode.swift, MarkdownEditor.swift, MarkdownRichTextView.swift}`, `Packages/EditorKit/Tests/EditorKitTests/MarkdownEditingTests.swift` (or a new `TextColumnTests.swift`).
Must NOT touch: `ReadingKit` (already 780), `MeetingsView.swift` (reuse `Color.headerBackground` as is), `SettingsView.swift`.

## Tests (EditorKit)

`horizontalInsetCentresWideViews` (1400 → 310; 796 → 16; 600 → 16; nil → 16), `textViewAppliesInsetOnResize` (make `MarkdownTextView.makeTextKit2()`, set `maxTextWidth = 780`, `setFrameSize(1400×600)` → `textContainerInset.width == 310` and `textContainer.size.width == 780`). `EditorMode.shortTitle` is trivially covered by `EditorFontPreferencesTests` style: one assertion of the three strings.

## Regression guard

- `setMode` hand-off (caret line ↔ reading top line) and `editorCaretLine()` window walk (`:1404-1428`) still find the text view (it is the same view; only the inset changed).
- Checkbox toggles, heading-fold margin clicks (`installFoldClickMonitor`, `:189-193`) and image clicks (`:856-883`) still hit the right line with the larger inset: verify at 1400 pt width.
- Autocomplete popover anchors (tags/links/mentions) still appear next to the caret.
- Tab strip, lock placeholder, proofread sheet, link sheet, image importer all open.
- The `.frame(minWidth: 380, idealWidth: 720)` on the pane and the inspector's 270 pt stay.

## Non-goals

iPhone/iPad header (Phase 3); editable title in the row (Rename sheet is spec 05); moving the stats chip; typographic changes to the text itself; animating the format cluster; per-note width settings; hover states (Phase 5 visual system).

## Builder model

sonnet.

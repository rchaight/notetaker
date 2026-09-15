# Spec 04 — Per-mode font family and size (Source / Live / Reading)

User request (2026-09-15, after confirming the three modes work): "add the
ability to set the font and font size for these screens."

## Scope

### Preferences model (pure, tested — `Packages/EditorKit/…/EditorFontPreferences.swift`)

- Each mode has its own font design and size. Storage keys (UserDefaults /
  `@AppStorage`), chosen so existing users keep what they have:
  - Live: `editorFontDesign` / `editorFontSize` (the EXISTING keys — Live is
    what they always applied to)
  - Source: `sourceFontDesign` / `sourceFontSize`
  - Reading: `readingFontDesign` / `readingFontSize`
- Designs are the existing string vocabulary: `system | serif | rounded |
  mono`. Sizes clamp to 11…28 pt. Defaults: size 16, design `system`.
- **Legacy migration, once**: if `sourceFontDesign` is unset, seed it from
  the old `sourceModeMonospace` toggle (`true`/absent → `mono`, `false` →
  Live's design); seed `sourceFontSize` and `readingFontSize` from
  `editorFontSize`, `readingFontDesign` from `editorFontDesign`. Then the
  `sourceModeMonospace` key is no longer read anywhere (leave the stored
  value alone). Implement as
  `EditorFontPreferences.migrateIfNeeded(store:)` over a small protocol
  (`get(String) -> Any?`, `set(String, Any)`) so tests use a dictionary and
  the app passes `UserDefaults.standard`.
- `EditorFontPreferences.resolve(mode:, store:) -> (design: String, size:
  CGFloat)` and `keys(for mode:) -> (design: String, size: String)`.
  `EditorMode` currently lives in the App target (NotesView.swift); either
  move the enum into EditorKit (preferred — Settings and NotesView both
  already import EditorKit) or key the API on a string. Moving it is fine;
  keep its raw values so the persisted `editorMode` still decodes.

### Settings › Editor

- Replace the single Font picker + Text-size stepper + "Source mode uses a
  monospaced font" toggle with a **"Fonts" section of three rows** — Source,
  Live Preview, Reading — each: design `Picker` (System / Serif / Rounded /
  Monospaced) + `Stepper("Size: N pt", 11…28)` + a per-row Reset (16 pt /
  System… for Source the reset design is Monospaced, matching the migration
  default). Bind each row directly to its `@AppStorage` keys.
- Caption: "⌘= and ⌘− resize the mode you're in; ⌘0 resets it."
- Keep the "Default mode for notes" picker where it is.

### Applying the fonts

- `NotesView`: the editor theme for Source and Live uses that mode's
  design/size (`theme.customized(baseFontSize:fontDesign:)`); the
  `readingStyle` uses Reading's. Remove the `sourceModeMonospace` read.
- **Immediate repaint on design change**: `MarkdownEditor.updateNSView`'s
  `modeChanged` check watches livePreview/focusMode/baseFontSize but not
  `fontDesign` (deferral #5 in 00-overview.md) — add `fontDesign` so
  changing a font in Settings while the note is open repaints without a
  keystroke. Same on the iOS side.
- **Quick zoom on the active mode** (macOS + iOS hardware keyboards):
  hidden buttons in the editor pane's existing shortcut stack (the ⌘F/⌘E
  pattern in NotesView) — `⌘=` (+1 pt), `⌘−` (−1 pt), `⌘0` (reset to 16)
  — writing to the ACTIVE mode's size key, clamped. `⌥⌘0` (inspector) must
  keep working; verify no other ⌘0/⌘=/⌘− bindings exist in the app.

## Acceptance criteria

1. EditorKit tests ≥ 8 for `EditorFontPreferences`: keys per mode; defaults
   when unset; clamp both ends; migration seeds Source→mono when the legacy
   toggle is true/absent and →Live's design when false; migration copies
   sizes; migration is idempotent (second run changes nothing); resolve
   after migration; unknown design string falls back to `system`.
2. All existing EditorKit / ReadingKit tests green; macOS + iOS builds
   green; swiftformat lint clean on changed files.
3. Behavior (verify by test where pure; otherwise report honestly what was
   and wasn't observed): changing Reading's size in Settings changes only
   Reading; ⌘= in Live changes only Live's stored size and Settings reflects
   it; a font-design change repaints the open note immediately.

## Files expected to change

- `Packages/EditorKit/Sources/EditorKit/EditorFontPreferences.swift` (new)
  + new test file; `EditorMode` moved into EditorKit if that route is taken
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditor.swift` (only the
  `modeChanged` checks in updateNSView / updateUIView)
- `App/Shell/SettingsView.swift` (Editor pane Fonts section)
- `App/Notes/NotesView.swift` (theme/readingStyle sources, zoom shortcuts,
  remove sourceModeMonospace)

## Non-goals

- Per-note font memory; custom font families beyond the four designs;
  line-height/width controls; changing the To-Do/Projects/Meetings fonts.

## Critique (pass, 2026-09-15) — deferrable notes

1. `EditorFontPreferences.resolve` is tested but unused; NotesView reads the
   raw `@AppStorage` values without clamping (only `defaults write` could
   put an out-of-range size in). Route the theme through `resolve` if it
   ever matters.
2. Zoom-in is ⌘= only; add ⌘⇧= (⌘+) if the Safari habit bites.
3. Settings rows, ⌘=/⌘−/⌘0, and immediate repaint were verified
   structurally, not observed live — 30-second shakedown check.

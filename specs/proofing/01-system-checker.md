# Spec 01 — System spelling + grammar, token-aware; autocorrect off

## Scope

### Step 0 — prototype the TextKit 2 squiggle/clobber question FIRST

Before wiring anything into the live editor, write a test (pattern:
`TableEditorKeyTests` — live `NSTextView` + real `MarkdownEditor.Coordinator`)
that: builds `MarkdownTextView.makeTextKit2()` with
`isContinuousSpellCheckingEnabled = true`, sets text containing a misspelled
word, forces a check (`checkTextInDocument(nil)` or
`NSTextCheckingController` / `NSSpellChecker` path — whatever produces the
spelling annotation), then calls `coordinator.restyle(textView)` (the full
attribute re-application) and inspects whether the spelling annotation
survives. Determine where TextKit 2 stores it (rendering attributes on
`NSTextLayoutManager` vs. storage attributes vs. temporary attributes) and
assert on that. Outcome A (survives): proceed. Outcome B (clobbered): the
coordinator must re-request checking for the restyled range after each
restyle/updateReveal (`textView.checkTextInRange(_:types:options:)` on the
affected window) — implement, and make the test prove survival. Report which
outcome you found; this is the highest-risk item and the reason this spec is
opus-routed.

### Exclusions (pure, tested — `Packages/EditorKit/…/ProofingExclusions.swift`)

`ProofingExclusions.ranges(in text: String, styled: [StyledRange]) -> [NSRange]`
(coalesced, sorted) covering: inline code + code blocks; the frontmatter
block (`MarkdownDocument.bodyUTF16Offset`); link destinations and autolink
URLs; image syntax; `[[wikilinks]]`; `.tag` / `.mention` / `.kindToken`
styled ranges; and on task lines every token TaskTokenParser recognizes
(`>date`, `!pN`, `^id`, `blockedby:^id` / `depends:^id`, `&every…`/`&after…`,
`✅date`). Bare URLs in prose (`https://…` not in link syntax) too. Task
token ranges MUST come from TaskEngine: if `TaskTokenParser` exposes no
per-token ranges, add `tokenRanges(in line:) -> [NSRange]` to it (with
tests) — no regex duplication in EditorKit.

### Editor wiring (both coordinators)

- macOS text view flags at creation and on cache reuse:
  `isContinuousSpellCheckingEnabled = spellOn`, `isGrammarCheckingEnabled =
  grammarOn`, `isAutomaticSpellingCorrectionEnabled = autocorrectOn`
  (default false). iOS: `spellCheckingType = spellOn ? .yes : .no`,
  `autocorrectionType = autocorrectOn ? .yes : .no`.
- New `MarkdownEditor` parameters `spellChecking: Bool = true`,
  `grammarChecking: Bool = true`, `autocorrect: Bool = false`, applied in
  make/update on both platforms (a change toggles the flag live).
- Delegate: implement
  `textView(_:didCheckTextIn:types:options:results:orthography:wordCount:)`
  returning only results whose range does NOT intersect
  `ProofingExclusions.ranges` for the current text (use the coordinator's
  cached `currentStyledRanges`; fall back to a fresh `MarkdownStyler.
  styleRanges` if the cache is stale by length). Also implement
  `textView(_:willCheckTextIn:options:types:)` to drop grammar checking
  when `grammarOn == false` (return options unchanged; clear the grammar bit
  via the inout types pointer) — or simply rely on the view flag if that
  suffices; state which.
- Writing Tools: implement
  `textView(_:writingToolsIgnoredRangesInEnclosingRange:)` returning the
  exclusion ranges intersected with the enclosing range, converted to the
  coordinate space the header documents (verify: relative to the enclosing
  range's substring or absolute — read the header comment in
  `NSTextView.h` and test both interpretations against a real Writing Tools
  session if the machine supports Apple Intelligence; otherwise document
  the choice and how you verified it).
- Reading mode is untouched (read-only, no checking).

### Settings › Editor

New "Proofing" section: toggles "Check spelling while typing" (default on),
"Check grammar" (macOS only, default on), "Correct spelling automatically"
(default OFF — user decision; caption: "Off keeps #tags, @handles and
identifiers exactly as typed; misspellings get an underline and right-click
suggestions instead"). Keys: `proofSpelling`, `proofGrammar`,
`proofAutocorrect`. NotesView passes them to the editor.

## Acceptance criteria

1. Step 0 test exists, passes, and its assertion proves annotation survival
   across a full restyle (whichever outcome/mitigation was needed).
2. `ProofingExclusions` tests ≥ 12: each excluded kind, coalescing of
   adjacent/overlapping ranges, a prose word adjacent to a token is NOT
   excluded, frontmatter absent vs present, CRLF text, empty text.
3. TaskEngine `tokenRanges` tests if added (≥ 5: each token kind, ordering,
   a plain line yields none).
4. Delegate filter test: a live NSTextView with text "teh #Amber1 @bob
   ?discuss >friday" — the check results fed through the coordinator's
   `didCheckTextIn` implementation keep "teh" and drop everything inside
   tokens (construct `NSTextCheckingResult`s directly if driving the real
   checker is nondeterministic).
5. Existing EditorKit tests green (≥ 198); macOS + iOS builds green; lint
   clean.
6. Manual (report honestly): open a note with a misspelling and tokens —
   squiggle under the misspelling, none under tokens; right-click offers
   suggestions; Learn Spelling works; toggling settings takes effect live.

## Files expected to change

- `Packages/EditorKit/Sources/EditorKit/ProofingExclusions.swift` (new) + tests
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditor.swift` (flags,
  parameters, delegate methods in both coordinators)
- `Packages/EditorKit/Sources/EditorKit/MarkdownRichTextView.swift` (only if
  flags belong at construction)
- `Packages/TaskEngine/Sources/TaskEngine/TaskTokenParser.swift` (+ tests) —
  only if token ranges are missing
- `App/Shell/SettingsView.swift` (Editor pane "Proofing" section ONLY)
- `App/Notes/NotesView.swift` (pass the three flags — ONLY the editor call
  site; spec 02 edits the note-action bar and adds a panel)

## Non-goals

LanguageTool/HTTP (spec 02). Custom squiggle drawing. Style linting.

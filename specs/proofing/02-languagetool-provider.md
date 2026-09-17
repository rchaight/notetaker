# Spec 02 — Self-hosted LanguageTool provider + Proofread panel

## Scope

### `Packages/ProofKit` (new; depends on MarkdownKit, TaskEngine, EditorKit —
for `ProofingExclusions` — and SecurityKit for `KeychainStore`)

- `GrammarProvider` protocol: `func check(_ text: String, excluding:
  [NSRange], language: String?) async throws -> [GrammarMatch]`.
- `GrammarMatch { range: NSRange (UTF-16, in the ORIGINAL text), message,
  shortMessage, replacements: [String], ruleId, category }`.
- `LanguageToolProvider(baseURL: URL)` → POST `{base}/v2/check` using the
  **annotated-text `data` parameter** (JSON `{"annotation":[{"text":…},
  {"markup":…}]}`) so every excluded range is sent as markup (LanguageTool
  skips markup and keeps offsets consistent) — `AnnotatedText.build(text:,
  excluding:)` is a pure, tested function that also maps LT's returned
  offsets back to UTF-16 ranges in the original (LT offsets are in the
  annotated string's code points — verify and test with an emoji + a token).
  `language: "auto"` by default; `withTimeout` 8 s (same helper AIKit uses);
  decode `matches[].{offset,length,message,shortMessage,replacements[].value,
  rule.id,rule.category.id}`. Errors surface as typed `GrammarError`
  (.unreachable, .timeout, .badResponse) — never crash on shape drift.
- Endpoint config: URL stored via `KeychainStore` (account
  `"languageToolURL"`, ThisDeviceOnly — homelab topology, same policy as
  `ollamaURL`), `ServerURL.normalize` applied.

### App: Proofread panel (NotesView) — macOS first, iOS builds

- Note-action bar gains a "Proofread" button (SF Symbol `text.badge.checkmark`
  — verify exists; fallback `checkmark.circle.badge.questionmark` or
  `text.magnifyingglass`; verify whichever you use) + `⇧⌘P`. Disabled with
  a tooltip when no LanguageTool URL is configured.
- Runs the provider on the whole note (or the selection when non-empty)
  with `ProofingExclusions.ranges(in:styled:)` (recompute via
  `MarkdownStyler.styleRanges`) as the exclusions. Shows a **sheet** (the
  app's proven pattern; not a popover, not `.inspector`) listing matches:
  message, the offending excerpt with context, replacement chips. Actions
  per match: **Apply** a replacement (through the existing
  `EditorCommandRequest` path with a NEW `.replaceRange(range, expected:,
  with:)` command in `MarkdownEditing` that no-ops when the document
  drifted — same guard as `.editLink`), **Ignore**. After an Apply, ranges of
  later matches shift — recompute by re-running or by offset arithmetic
  (state which; test it). "Ignore rule for this session" optional.
- States: running (spinner + Cancel), results, "No issues found", error
  text ("LanguageTool unreachable at … — check Settings › AI & Import").
- Never mutates `model.noteText` directly; every Apply goes through the
  editor command so undo works.

### Settings › AI & Import

New "LanguageTool" section: URL field (Keychain-backed like the Ollama
field), "Test connection" button hitting `{base}/v2/languages` with the
result shown inline, caption: "Self-hosted grammar checking. Run the
`erikvl87/languagetool` container on your homelab; nothing leaves your
network." Optional "Preferred language" picker seeded from `/v2/languages`
(default Auto).

## Acceptance criteria

1. ProofKit tests ≥ 12: `AnnotatedText.build` (tokens → markup, offsets
   round-trip incl. emoji and CRLF, adjacent exclusions, empty exclusions),
   response decoding from a fixture JSON (real LT shape), error mapping for
   404/timeout/malformed, `GrammarMatch` ranges landing on the intended
   words in the ORIGINAL text.
2. `MarkdownEditing` `.replaceRange` tests (≥ 3: applies, drift no-op,
   bounds).
3. Existing tests green; macOS + iOS builds green; lint clean;
   `project.yml` gains the package (commit `project.yml`; xcodeproj is
   gitignored).
4. Manual (report honestly): if a LanguageTool instance is reachable from
   this machine (check Settings/Keychain — do NOT read secrets files; if
   none is configured, say so), run a proofread on a note with a
   deliberate grammar error and a `#tag`: the error is listed, the tag is
   not; Apply rewrites the right span; ⌘Z undoes. Otherwise state clearly
   that live verification was not possible.

## Files expected to change

- `Packages/ProofKit/**` (new), `project.yml`
- `Packages/EditorKit/Sources/EditorKit/MarkdownEditing.swift` (`.replaceRange`
  + tests) — spec 01 does not touch this file
- `App/Notes/NotesView.swift` (note-action button, sheet, apply plumbing —
  NOT the editor call-site flags spec 01 adds)
- `App/Shell/SettingsView.swift` (AI & Import pane section ONLY)

## Non-goals

Inline squiggles from LanguageTool (system checker owns squiggles); n-gram
data setup docs beyond a caption; iOS panel polish; Harper; Ollama.

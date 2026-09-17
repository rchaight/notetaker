# Spell + grammar checking — plan overview (2026-09-17)

Research verdict (sonnet agent, sources in the session record): Apple's
continuous spell/grammar checking is the zero-dependency, on-device
foundation (grammar is macOS-only; iOS has spelling only); its grammar rules
are weak, so a stronger provider is a separate optional layer. The user
chose: (1) the system checker with a token-aware filter and autocorrect OFF,
(2) a self-hosted LanguageTool provider on the homelab. Declined for now:
Harper (no Swift binding exists), Ollama proofread-on-demand.

Empirical facts from this session: a programmatically created NSTextView on
this OS starts with continuous spell checking OFF, grammar checking OFF,
automatic spelling correction ON, automatic text completion ON — so today the
editor shows no squiggles but silently autocorrects, with nothing protecting
`#tag`/`@handle` words. Writing Tools (`.complete`) is enabled with no
ignored ranges. SDK headers (Xcode 27) confirm the hooks:
`textView(_:willCheckTextIn:options:types:)`,
`textView(_:didCheckTextIn:types:options:results:orthography:wordCount:)`
(returns the results to KEEP), and
`textView(_:writingToolsIgnoredRangesInEnclosingRange:)` (macOS 15+).

## Tasks

| # | spec | builder | files |
|---|------|---------|-------|
| 01 | System spelling + grammar, token-aware; autocorrect off; Writing Tools ignores | opus, worktree | EditorKit (new `ProofingExclusions.swift`, coordinator hooks, view flags), TaskEngine only if token ranges are missing, `SettingsView.swift` (Editor pane toggles) |
| 02 | LanguageTool provider + Proofread panel | sonnet, worktree | new `Packages/ProofKit`, `project.yml`, `NotesView.swift` (note-action button + panel), `SettingsView.swift` (AI & Import pane URL/test) |

Both touch `SettingsView.swift` (different panes) → worktrees; orchestrator
merges 01 → 02, full gate, fresh critic, push on pass.

## Shared rule

One exclusion oracle. Spec 01 defines `ProofingExclusions.ranges(in:styled:)`
(EditorKit, pure): code spans/blocks, frontmatter, URLs/link destinations,
images, wikilinks, `#tag` / `@mention` / `?kind` chips, and task-line tokens
(`>date !pN ^id blockedby:/depends: &every/&after ✅date`). Spec 02 must
consume the SAME function to mark those spans as markup for LanguageTool —
never a second regex set. Task-token ranges come from TaskEngine's
`TaskTokenParser` (the ONE parser); if it exposes no ranges today, extend it
(spec 01) rather than re-regexing.

## Non-goals (both)

- No cloud grammar APIs. No auto-applied rewrites (every change is a user
  action). No Harper/Ollama this round. No change to what is written to disk
  except user-accepted replacements through the existing editor command path.

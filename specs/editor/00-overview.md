# Editor WYSIWYG ergonomics — plan overview

User direction (2026-08-20, after research on stevengharris/MarkupEditor):
**do not adopt MarkupEditor** — it is a WKWebView/ProseMirror HTML editor with
zero markdown awareness; bridging it would mean a JS-side re-implementation of
the task grammar and a lossy HTML↔md round trip against the .md-is-truth
invariant. Instead, close the WYSIWYG ergonomics gaps it highlights, natively,
in the existing TextKit 2 editor where markdown stays the document.

Research assessment is preserved in the conversation record; key borrowed UX
ideas: mouse/keyboard table editing, rich paste, image drag-drop, selection-
aware toolbar state, link dialogs.

## Tasks

| # | spec | builder | overlap notes |
|---|------|---------|---------------|
| 01 | Table editing UX | opus, worktree | doCommandBy region of MarkdownEditor.swift; formatBar insert menu |
| 02 | Rich paste + drop | sonnet, worktree | view-creation region of MarkdownEditor.swift (new text-view subclasses); NotesView wiring |
| 03 | Selection-aware toolbar, link editing, image polish | sonnet, worktree | selection-change region of MarkdownEditor.swift; formatBar button styling |

All three touch `MarkdownEditor.swift` in different regions and 01/03 touch
`NotesView.swift` in different regions — worktrees required; orchestrator
merges 01 → 02 → 03 and resolves conflicts, full verify gate after merge,
fresh critic before push.

Shakedown-era work: commits use the `Editor:` prefix, no PLAN.md checkboxes;
PROGRESS.md rows written by the orchestrator at merge.

## Non-goals (all tasks)

- No WKWebView, no HTML document model, no external editor frameworks.
- No changes to the task-token grammar or TaskTokenParser.
- No new markdown syntax; everything written to disk stays CommonMark +
  existing extensions (wikilinks, ==highlight==, tokens).
- iOS: must keep building and keep current behavior; new interactions are
  macOS-first, brought to iOS only where the spec says so.

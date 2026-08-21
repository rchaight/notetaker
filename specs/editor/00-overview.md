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

## Deferred follow-ups (from the post-merge critique round 1 — fixed items excluded)

1. Async image-import race: caret captured at paste, insertion after the
   await — typing during a slow Attachments write lands `![...]` at a stale
   offset or drops it via the bounds guard.
2. imageClickMonitor binds the first text view per process-cached
   coordinator — image clicks dead in a second window (mirror of the fold
   monitor's inverted variant; consolidate the two monitors' rebind story).
3. iOS hand-rolled paste undo uses absolute ranges — silently no-ops if the
   stack ever desyncs (bounds-guarded, no crash).
4. Fixed 290pt paragraph reservation under standalone images doubles the
   gap below small images now that the cap is 280pt — track drawn size.
5. linkWrapping doesn't escape `]`/newlines in the selection — malformed
   (but content-preserving) link markdown on exotic selections.
6. Live-UI verification of table Tab flow, paste variants, link sheet, and
   image click still owed by daily use — builders and orchestrator ran
   headless.

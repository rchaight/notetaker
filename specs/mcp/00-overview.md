# MCP + RAG integration — plan overview

Goal: Notetaker's vault becomes a first-class knowledge source for Claude
(Claude Code / Claude Desktop). Two complementary layers:

1. **Vault context files** (works with NO server at all): the app maintains
   `_index.md` tables of contents in every folder and seeds a `CLAUDE.md` at
   the vault root with instructions for Claude. Any agent pointed at the vault
   folder reads `CLAUDE.md` → follows `_index.md` files → opens only the notes
   it needs. This is agentic RAG over plain files — zero moving parts, and it
   honors the One Invariant (everything derivable from the files).

2. **`notetaker-mcp` server** (structured retrieval): a small stdio
   executable bundled inside Notetaker.app that Claude launches on demand.
   It reads the vault files directly and opens the GRDB index **read-only**
   for FTS5 keyword search and semantic (embedding) search. Read-only in v1 —
   Claude retrieves; it does not write into the vault.

## Architecture decisions (with reasoning)

- **stdio executable, not an app-hosted HTTP server.** Claude Code's native
  local-server pattern; works even when Notetaker isn't running; no port or
  auth surface. The app is unsandboxed (Developer ID path), so a bundled CLI
  can read `~/Library/Mobile Documents/iCloud~com~rchaight~notetaker/Documents`
  and the index DB directly.
- **Official MCP Swift SDK** (`modelcontextprotocol/swift-sdk`, product
  `MCP`): Swift 6, macOS 13+, `StdioTransport` built in. New package
  `Packages/MCPKit` holds all logic (testable); the `notetaker-mcp` target is
  a thin main.
- **Index is an accelerator, never a requirement.** The server opens the DB
  with a new `IndexDatabase.openReadOnly()` that never migrates and throws on
  schema-version mismatch; on any failure it falls back to scanning the .md
  files. The vault files stay the single source of truth.
- **Locked notes never leak.** Bodies are AES-GCM encrypted on disk already;
  the server additionally detects `locked: true` frontmatter and returns
  title-only. `_index.md` lists locked notes as title + 🔒.
- **The app never edits Claude's own config** (`~/.claude.json` holds
  secrets — global rule). Settings shows a copyable
  `claude mcp add notetaker -- <path>` command instead of writing config.
- **macOS only.** iOS can't bundle a spawnable CLI; the context files (layer
  1) still work everywhere since they're just vault files.

## Task decomposition (independently buildable)

| # | spec | builder | why |
|---|------|---------|-----|
| 01 | Vault context files (`_index.md` + `CLAUDE.md` seed) | sonnet, worktree | well-specified rendering + wiring |
| 02 | MCPKit package + `notetaker-mcp` executable | opus, worktree | cross-process DB access, new target/signing, concurrency |
| 03 | Settings UI + docs (owns ALL SettingsView edits) | sonnet, worktree | small, disjoint by assignment |

Merge order 01 → 02 → 03; regenerate xcodeproj + full `scripts/verify.sh`
after each merge; fable critic on the combined diff (Phase 3, max 3 rounds).

## Non-goals (v1)

- Write tools (add_task, append_to_daily_note) — future v2, behind a
  Settings toggle, routed through the quick-add grammar into Inbox.md.
- Direct HTTP/remote access, multi-machine serving, auth.
- iOS/visionOS server.
- Embedding model changes — reuse the existing NLContextualEmbedding chunks.

## Open decisions for the user

1. `_index.md` generation ON by default (recommended — it's the feature), or
   opt-in via Settings?
2. Should `CLAUDE.md` at the vault root appear as a normal editable note in
   the app (recommended — you'll want to tune the instructions), while
   `_index.md` files are hidden from all note lists?
3. Any appetite for one safe write tool in v1 (`add_task` → Inbox.md), or
   strictly read-only until the read path proves itself? (Spec assumes
   strictly read-only.)

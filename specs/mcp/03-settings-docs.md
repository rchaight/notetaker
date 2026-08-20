# Spec 03 — Settings UI + documentation (owns ALL `SettingsView.swift` edits)

## Scope

### Settings › AI & Import → new "Claude integration" section

(Or a dedicated pane if the AI pane is crowded — builder's call, one or the
other, macOS-relevant content compiles out cleanly on iOS.)

- **Vault context files** toggle bound to the spec-01 storage key
  (`claudeIndexFiles`, default true): "Maintain _index.md tables of contents
  and a CLAUDE.md guide in the vault for AI assistants." Caption when off:
  existing files are left in place but no longer updated.
- **MCP server** block (macOS only):
  - Resolved binary path (from `Bundle.main` → `Contents/MacOS/notetaker-mcp`),
    with a "binary missing" warning state if not found.
  - A copyable install command in a monospaced field + Copy button:
    `claude mcp add notetaker -- "<path>" ` and a second line for Claude
    Desktop users pointing to its MCP settings UI. **The app must never write
    to `~/.claude.json` or Claude Desktop's config itself** (secrets policy).
  - Caption: read-only access; works while Notetaker is closed; locked notes
    are never exposed.
- Follow the existing SettingsView idiom (Form + Sections, caption
  `.font(.caption).foregroundStyle(.secondary)`).

### Documentation

- `FEATURES.md`: new "Claude / MCP integration" section — the two layers
  (context files, stdio server), read-only v1 decision, locked-note
  redaction, index-with-scan-fallback design, macOS-only server.
- `PLAN.md`: add milestone **M9.8 — Claude/MCP integration** (placed within
  the shakedown era; M10 stays deferred) with checkboxes matching specs
  01/02/03; check them as the merges land.
- `README.md`: short "Use your vault with Claude" subsection: enable in
  Settings, run the `claude mcp add` command, what Claude can then do.
- `CLAUDE.md` (repo agent guide): one line in the architecture section for
  MCPKit + the `notetaker-mcp` target, and a "known trap" note that
  `_index.md` files are app-generated and excluded from indexing.
- `PROGRESS.md` pass row.

## Acceptance criteria

1. Both platforms build; Settings shows the section on macOS; nothing broken
   on iOS.
2. Copy button puts the exact runnable command on the pasteboard; path shown
   matches the built app's real binary location.
3. Toggle round-trips the same defaults key spec 01 reads.
4. Docs updated as listed; `scripts/verify.sh 1 --install` green.

## Files expected to change

- `App/Shell/SettingsView.swift` (this spec's exclusive file)
- `FEATURES.md`, `PLAN.md`, `README.md`, `CLAUDE.md`, `PROGRESS.md`

## Non-goals

- Generation logic (spec 01), server code (spec 02), `project.yml`.
- Auto-editing any Claude configuration file.

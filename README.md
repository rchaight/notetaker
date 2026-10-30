# Notetaker

Native macOS + iOS markdown notes, todos, and project management — plain `.md` files in iCloud as the single source of truth.

- **Notes** — Obsidian-style markdown vault with a native Liquid Glass live-preview editor (CommonMark/GFM).
- **Todos** — inline `- [ ] task >due !priority #tag` in any note, aggregated into a live bidirectional master To-Do tab.
- **Projects** — Gantt/timeline, dependencies, and progress tracking as views over the same todos.
- **Import** — PDF/DOCX/PPTX/image/audio → Markdown (native Vision/Speech + Docling via [File-Parser](https://github.com/rchaight/File-Parser)).
- **AI** — on-device Apple Intelligence or local Ollama, private by default.

## Use your vault with Claude

Notetaker's vault works as a knowledge source for Claude Code/Desktop, on macOS:

1. In Settings › AI & Import, leave "Maintain `_index.md` tables of contents and a `CLAUDE.md` guide" enabled (default) — the app keeps machine-written folder indexes and a root `CLAUDE.md` up to date so any agent pointed at the vault folder can navigate it without a server.
2. For structured search and task queries even while Notetaker is closed, copy the `claude mcp add notetaker -- "<path>"` command shown in that same section and run it once. Claude Code (or Claude Desktop, via its MCP settings) can then search notes, read a note, list a folder, or pull tasks — read-only, with locked notes never exposed. Calendar tools (`calendar_agenda`, `calendar_list`) are off until you turn on Settings › Calendar › "Share upcoming events with the MCP server". Notetaker never edits Claude's own configuration for you.

### From claude.ai web and phone (your own server)

If you run a small Linux container (for example on a Proxmox homelab), Notetaker can keep a filtered, read-only copy of your vault there so claude.ai on the web or your phone can search and read it while the Mac is off. Turn it on in Settings › Remote ("Copy my notes to my container for claude.ai"); locked notes, `_index.md` files, excluded folders and `remote: false` notes are never copied, and the connector signs in with a single Google account you allowlist. Turning the toggle off wipes the copy on the container, and `nr-kill` on the host is the hard stop. Everything else (container setup, Tailscale Funnel, Google OAuth client, the stage checks in `scripts/remote-vault/` and the risks you are accepting) is in [deploy/remote-vault/RUNBOOK.md](deploy/remote-vault/RUNBOOK.md); the design is `specs/remote-vault/00-security-design.md`.

## Documents

| File | Purpose |
|---|---|
| [FEATURES.md](FEATURES.md) | Competitive landscape, core design decisions, tiered feature outline |
| [PLAN.md](PLAN.md) | Architecture + implementation milestones M0–M10 (checkbox steps) |
| [RESEARCH.md](RESEARCH.md) | Full competitive & technical research (2026-07) |
| [PROGRESS.md](PROGRESS.md) | Build-loop contract, state, and pass log |

## Status

Alpha, in daily use. Milestones M1–M9.7 are built — vault + editor, todo engine, projects/Gantt, import pipeline, on-device AI, app lock, App Intents, widgets, and meeting/daily notes. Current phase is **M9.9 ongoing shakedown**: the app is driven day-to-day and reported issues jump the queue. M10 (release/distribution) is deferred pending an explicit go. See [PROGRESS.md](PROGRESS.md).

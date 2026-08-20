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
2. For structured search and task queries even while Notetaker is closed, copy the `claude mcp add notetaker -- "<path>"` command shown in that same section and run it once. Claude Code (or Claude Desktop, via its MCP settings) can then search notes, read a note, list a folder, or pull tasks — read-only, with locked notes never exposed. Notetaker never edits Claude's own configuration for you.

## Documents

| File | Purpose |
|---|---|
| [FEATURES.md](FEATURES.md) | Competitive landscape, core design decisions, tiered feature outline |
| [PLAN.md](PLAN.md) | Architecture + implementation milestones M0–M10 (checkbox steps) |
| [RESEARCH.md](RESEARCH.md) | Full competitive & technical research (2026-07) |
| [PROGRESS.md](PROGRESS.md) | Build-loop contract, state, and pass log |

## Status

Alpha, in daily use. Milestones M1–M9.7 are built — vault + editor, todo engine, projects/Gantt, import pipeline, on-device AI, app lock, App Intents, widgets, and meeting/daily notes. Current phase is **M9.9 ongoing shakedown**: the app is driven day-to-day and reported issues jump the queue. M10 (release/distribution) is deferred pending an explicit go. See [PROGRESS.md](PROGRESS.md).

# Spec 02 — `Packages/MCPKit` + bundled `notetaker-mcp` stdio executable

## Scope

A macOS-only MCP server binary, bundled inside Notetaker.app, that Claude
Code/Desktop spawns over stdio. Read-only in v1: it retrieves, never writes.

### Package: `Packages/MCPKit`

- Depends on: official MCP Swift SDK
  (`https://github.com/modelcontextprotocol/swift-sdk`, product `MCP`),
  IndexKit, MarkdownKit, TaskEngine, AIKit (embeddings). No app imports.
- All server logic lives here so `swift test` covers it; the executable
  target is a ~10-line `main`.

### Vault + index resolution (no app running required)

- Vault root, in order: `--vault <path>` argument → active custom vault from
  `UserDefaults(suiteName: "com.rchaight.notetaker")` (same keys
  `VaultRegistry` uses) → the literal iCloud path
  `~/Library/Mobile Documents/iCloud~com~rchaight~notetaker/Documents`
  (constructible directly because the tool is unsandboxed). Error out with a
  clear stderr message if the resolved root doesn't exist.
- Index DB: `~/Library/Application Support/Index/index.sqlite` (or
  `index-<vaultId>.sqlite` for custom vaults — mirror `VaultIndexService`'s
  naming exactly).
- **New API in IndexKit:** `IndexDatabase.openReadOnly(path:)` — GRDB
  `Configuration` with `readonly = true`, `busyMode = .timeout(1.0)`;
  reads `PRAGMA user_version` and **throws on schema mismatch — it must never
  run migrations or the wipe-and-rescan path.** Unit-test: read-only open of
  a current-version DB works; mismatched version throws; no write occurs.
- **Every index-backed tool has a file-scan fallback.** If the DB is missing,
  busy, or version-mismatched, tools degrade to enumerating `*.md` under the
  root (skipping `_index.md`) and parsing with MarkdownKit/TaskTokenParser.
  Responses include `"source": "index"` or `"source": "scan"` so degradation
  is visible.

### MCP tools (v1, all read-only)

1. `vault_overview` — returns root `CLAUDE.md` content (if present) + root
   `_index.md` (or a computed folder/file tree if the context files don't
   exist yet). Claude's entry point.
2. `list_folder { path }` — the folder's `_index.md` if present, else a
   computed listing in the same format.
3. `read_note { path }` — coordinated read (NSFileCoordinator) of one note.
   iCloud placeholder (`.Name.md.icloud`): call
   `startDownloadingUbiquitousItem`, poll up to ~5 s, else return a
   "not downloaded locally — open it in Notetaker first" error. Notes with
   `locked: true` frontmatter return title + `"locked": true` and NO body.
4. `search { query, mode?: "keyword" | "semantic" | "hybrid" }` — default
   hybrid: FTS5 BM25 (`searchNoteIds`) merged with cosine over `noteChunk`
   embeddings (embed the query via `AppleEmbeddingProvider` /
   NLContextualEmbedding — available to CLI processes; if assets are
   unavailable, silently keyword-only). Returns ranked entries: path, title,
   best-matching snippet (from FTS or the matched chunk text), score.
   Locked notes: title only, no snippet.
5. `tasks { due_within_days?, assignee?, kind?, label?, include_completed? }`
   — task records (clean text, due, priority, tags, assignee, kind, source
   note path + line) from the index, with scan fallback via TaskTokenParser.

- Server name `notetaker`, version = app marketing version. Tool
  descriptions must be written for the model (what it's for, when to use).

### Target + bundling (`project.yml` — this spec owns it)

- New target `NotetakerMCP` (product name `notetaker-mcp`): `type: tool`,
  `supportedDestinations: [macOS]`, sources `MCPServer/` (the thin main),
  depends on package `MCPKit`. Hardened runtime + Automatic signing like the
  app (it must survive future notarization).
- App target: dependency on `NotetakerMCP` with a **copy-files phase into the
  bundle's executables directory** (`Contents/MacOS/`), not the default
  frameworks embed. Builder must verify post-build:
  `Notetaker.app/Contents/MacOS/notetaker-mcp` exists, is signed
  (`codesign -dv`), and runs (`--help` exits 0).
- iOS build must remain green — the tool target must not enter the iOS build
  graph.

### Protocol smoke test

- MCPKit test (or a script the builder runs and records): launch the binary,
  send `initialize` + `tools/list` + one `tools/call` (vault_overview against
  a fixture vault) over stdio, assert well-formed JSON-RPC responses. If the
  SDK makes an in-process test harness easier than spawning, in-process is
  acceptable — the spawn check then happens once manually and is noted in the
  report.

## Acceptance criteria

1. `swift test` green in MCPKit (resolution logic, read-only open behavior,
   tool handlers over a fixture vault + fixture DB, locked-note redaction,
   fallback path when DB absent).
2. Protocol smoke test passes (initialize / tools/list / tools/call).
3. Binary embedded at `Contents/MacOS/notetaker-mcp`, signed, `--help` works.
4. With the app closed: `claude mcp add`-style stdio invocation against the
   real vault returns sensible `vault_overview` and `search` results
   (builder demonstrates with a transcript in its report).
5. DB deleted/renamed → tools still answer via scan fallback with
   `"source": "scan"`.
6. `scripts/verify.sh 1 --install` green, including the iOS build.

## Files expected to change

- `Packages/MCPKit/**` (new), `MCPServer/main.swift` (new)
- `Packages/IndexKit/Sources/IndexKit/IndexDatabase.swift` (`openReadOnly`) + tests
- `project.yml` (+ regenerated `Notetaker.xcodeproj`)
- `PROGRESS.md` (pass row)

## Non-goals

- Any write/mutation tool. Settings UI (spec 03; do NOT touch
  `SettingsView.swift`). `_index.md` generation (spec 01; if its files are
  present, just read them). HTTP transport. MCP resources/prompts (tools
  only in v1).

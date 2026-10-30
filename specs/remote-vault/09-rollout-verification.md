# Spec 09 — Stage 1–3 verification scripts, drills, and documentation

Design: `00-security-design.md` §7 (stages 1–3), §4.8 (audit anomaly cues),
§5 item 4 (operational audit), §6 (residual risks — must be stated in the
docs the way the design states them), §7 T9. Depends on everything.
Builder: sonnet. Stage: 1 → 3.

## Scope

Scripts the user runs at each stage from the Mac (never from a builder's
session against the homelab), drill procedures, an audit-log summariser,
and the documentation updates (`FEATURES.md`, `README.md`, `CLAUDE.md`,
`PLAN.md`, `PROGRESS.md`). No product code.

## Deliverables

### `scripts/remote-vault/` (bash; `set -euo pipefail`; curl + jq; no secrets stored — tokens come from `oauth-probe.sh`'s temp file for the duration of a run)

| script | stage | what it checks (exit 0 only if every line passes; prints PASS/FAIL per line) |
|---|---|---|
| `stage1-check.sh <PUBLIC_URL>` | 1 (tailnet) | PRM doc at both `/.well-known/oauth-protected-resource` and `…/mcp` with `resource == <PUBLIC_URL>/mcp`; AS metadata at both discovery paths with no `registration_endpoint`, `S256` only, `none` auth; `POST /mcp` no token → 401 + `WWW-Authenticate` containing `resource_metadata=`; `GET /mcp` → 405; `/register` → 404; `/healthz` → not 200; 70 KB body → 413; 25 unauthenticated POSTs → at least one 429 with `Retry-After` |
| `stage1-tools.sh <PUBLIC_URL> <client_id>` | 1 | runs `oauth-probe.sh` non-interactively where possible, then with the access token: `tools/list` has exactly 7 names and `search` schema has no `mode`; `vault_overview` carries `replica_generated_at`, `stale`, `index_status == "ok"`, `note_count > 0`; `search {"query":"locked"}` → every result `locked == false` unless `snippet` absent; `read_note` on a path the user supplies as `$LOCKED_PATH` (a locked note's vault path, title only) → `locked:true`, no `content`; `read_note` on `$BIG_PATH` (optional) → `truncated` consistent with size; `calendar_agenda {"range":"custom","from":…,"to":+61d}` → error "max 60 days"; text content starts with the untrusted-data preamble |
| `stage2-check.sh <PUBLIC_URL>` | 2 (public) | same as stage1-check minus nothing — intended to run from a non-tailnet network (phone hotspot); additionally asserts the TLS chain is valid (`curl` without `-k`) and that `/auth/google/callback` without params → 400 not 500 |
| `drill-token-reuse.sh <PUBLIC_URL> <client_id>` | 3 | full probe: refresh once, reuse the old refresh token → `invalid_grant`; the newest access token → 401; then logs the audit expectation ("look for refresh.reuse") |
| `drill-kill-mac.md` | 3 | numbered steps: toggle off in Settings → within 60 s `vault_overview` via a valid token answers `available:false` with the "disabled in Notetaker" reason → `ls` of the inbox shows two files → toggle on → Push now → `available:true` again |
| `drill-kill-ct.md` | 3 | `pct exec <id> -- notetaker-remote kill` → the public URL stops answering (Funnel off) → recovery steps from 08 §G → the connector must re-authenticate (old tokens gone) |
| `drill-backup.md` | 3 | 08 step 23 restated as a drill with the expected `0` counts, plus `pct config <id> | grep mp0` → `backup=0` |
| `audit-summary.sh [path]` | ongoing | jq over `audit.jsonl` (the user copies it to the Mac with `pct pull`): counts per `event`, per `tool`, distinct `ip` values, every `login.denied` / `refresh.reuse` / `code.reuse` / `replica.contaminated` / `auth.tarpit` line verbatim, p95 `ms` per tool, bytes per day; prints "ANOMALIES: n" at the end |

### Documentation

- `FEATURES.md` §3.5 Claude / MCP integration: a new bullet "Remote vault
  for claude.ai (web + phone)": one-way filtered replica on a homelab
  container, read-only HTTP MCP server, Google-login-gated OAuth for one
  account, what is never copied (locked notes, `_index.md`, hidden,
  non-md, excluded folders, `remote: false`, event notes/links/emails),
  keyword-only search, kill switches, and the **residual risks in the
  design's own words** (§6, first three bullets, condensed but not
  softened).
- `README.md`: new subsection under "Use your vault with Claude" —
  "From claude.ai web and phone (your own server)": three sentences + a
  pointer to `specs/remote-vault/08-container-runbook.md`; the Settings ›
  Remote toggle; the "turning it off wipes the copy" statement.
- `CLAUDE.md`: architecture list gains `Packages/RemoteServer` + the
  `notetaker-remote` binary (Linux, container-hosted, read-only replica
  server, OAuth AS); the MarkdownKit line gains "+ `ExportPolicy` (remote
  export gate)"; VaultKit line gains "+ `ReplicaExporter`"; Known traps
  gains: "`/usr/bin/rsync` on macOS is openrsync — the remote push uses
  only `-rlt --delete --timeout --exclude -e`"; "`verify.sh` tests every
  `Packages/*/` including `RemoteServer` (Hummingbird) — it must keep
  building on macOS"; "No Docker on the dev Mac: Linux is verified by the
  `linux-packages` CI job". Build & verify gains the Linux CI sentence.
  Secrets section gains `/etc/notetaker-remote/env` and
  `~/Library/Application Support/Notetaker/RemoteExport/id_ed25519`.
- `PLAN.md` M9.9: bullets for specs 02–09 as checked items with their
  commit prefixes; M10 note: "the Developer ID build must still embed
  `notetaker-mcp` only — `notetaker-remote` is never shipped in the .app".
- `PROGRESS.md`: the rollout row(s): stage 1 results (user-run steps,
  openrsync outcome, Claude Code client-ID outcome), stage 2 (Funnel,
  forwarded-IP observation), stage 3 drills, one-week audit review date.

## Acceptance criteria

1. All scripts `bash -n` + `shellcheck` clean; each prints a PASS/FAIL
   line per check and a final summary; no script stores a token on disk
   outside a `mktemp` file removed by `trap`.
2. `stage1-check.sh` run **by the builder against a local loopback
   instance** of `notetaker-remote` (fixture replica, `NR_PUBLIC_URL=http://127.0.0.1:8787`
   — allow `http` for loopback in the script via `--insecure-loopback`)
   passes every line except the TLS one (skipped on http). This is the
   builder's only execution; the tailnet/public runs are the user's.
3. Docs updated as listed; `CLAUDE.md` architecture list stays
   alphabetically consistent with the existing order; no doc claims a
   stage is done — stages are recorded in PROGRESS when the user reports
   them.
4. `scripts/verify.sh 3 --install` green (no code change, but the gate is
   the commit rule).

## Files expected to change

- new `scripts/remote-vault/{stage1-check.sh,stage1-tools.sh,stage2-check.sh,drill-token-reuse.sh,audit-summary.sh,drill-kill-mac.md,drill-kill-ct.md,drill-backup.md}`
- `FEATURES.md`, `README.md`, `CLAUDE.md`, `PLAN.md`, `PROGRESS.md`

Must not change: any `Packages/`, `App/`, `deploy/` file; `specs/` (user annotations go in PROGRESS).

## Non-goals

- Automated stage-2/3 runs from CI or from a builder; load testing;
  monitoring/alerting (the audit summary is a manual weekly step by
  design); a dashboard.

## Verification commands

```bash
cd ~/Developer/Notetaker && for f in scripts/remote-vault/*.sh; do bash -n "$f"; done
command -v shellcheck && shellcheck scripts/remote-vault/*.sh || true
# builder-only local run (fixture replica from spec 06's tests, copied to /tmp/nr-fixture):
NR_PUBLIC_URL=http://127.0.0.1:8787 NR_REPLICA_DIR=/tmp/nr-fixture NR_STATE_DIR=/tmp/nr-state NR_AUDIT_LOG=/tmp/nr-audit.jsonl \
  NR_ALLOWED_EMAIL=test@example.com NR_OAUTH_CLIENT_ID=nr-test NR_GOOGLE_CLIENT_ID=x NR_GOOGLE_CLIENT_SECRET=y \
  ~/.cache/notetaker-build/RemoteServer/release/notetaker-remote serve &   # background in the harness
scripts/remote-vault/stage1-check.sh http://127.0.0.1:8787 --insecure-loopback
scripts/verify.sh 3 --install   # exit code captured directly
```

## Builder notes

**sonnet.** The scripts are the user's hands at each stage; write them so
a failure names the design section it contradicts (e.g. "FAIL:
/register answered 200 — §9 says no registration endpoint"). Docs: copy
the design's residual-risk language; do not editorialise it away.

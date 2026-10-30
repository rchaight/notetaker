# Remote vault for Claude.ai — build overview

Status: BUILD SPECS, 2026-10-29. The approved design is `00-security-design.md`;
its §9 records the user's final decisions and supersedes §8 wherever they
differ. Every spec below cites the design by section. Nothing here changes a
decision; where §9 narrows the design, the overview says so and the task
shrinks accordingly.

## What §9 changed in the task list

- **Calendar schema 2 is gone.** §9: "full detail minus email addresses,
  meeting URLs and event notes/description; honors Settings calendar
  exclusions. Title, times, location, organizer/attendee names, status."
  That is exactly the field set `CalendarKit.CalendarEvent` already has
  (`CalendarModel.swift`: "Deliberately absent: notes/description, URL,
  attendee emails"; `CalendarService.events` even drops participant names
  that are email addresses). So design T4 collapses into one job inside
  spec 04: write a second snapshot file (`calendar-remote.json`, wider
  range) into the export staging dir with the existing codec. No CalendarKit
  change, no MCPKit change for calendar.
- **No dynamic client registration.** §9: pre-registered client, fixed
  client ID pasted into the claude.ai connector dialog. Spec 07 has no
  `/register`, no DCR policy, no live-client cap; the AS metadata omits
  `registration_endpoint`. Client registration is one env var.
- **Keyword-only search, no outbound calls** except Google OIDC and
  Tailscale. The container's `VaultService` runs with a `NoEmbeddingProvider`
  and the remote `search` tool advertises keyword only.
- **Push cadence**: on change (30 s debounce) + 5-minute timer.
- **Anthropic egress allowlist OFF** initially; client-IP passthrough through
  Funnel is unverified, so per-IP limits degrade to global until stage 2
  confirms the header.
- **Encryption at rest**: host-opened LUKS thin LV, `mp0 backup=0`. Unlock
  procedure chosen in spec 08: a root-only key file on the host opened by a
  systemd unit ordered before `pve-guests`; if unlock fails the CT does not
  start, so nothing is served while the volume is locked (spec 08 §B states
  this and the manual-passphrase alternative).

## Specs

| # | spec | side | builder | depends on | stage | infra needed to build + test |
|---|------|------|---------|------------|-------|------------------------------|
| 02 | `02-export-policy.md` — `MarkdownKit.ExportPolicy`, the gate that keeps locked notes and `_index.md` home | Mac | **opus** | — | pure | none |
| 03 | `03-replica-exporter.md` — `VaultKit.ReplicaExporter` + `manifest.json` + self-check + disabled marker | Mac | sonnet | 02 | pure | none |
| 04 | `04-remote-replica-service.md` — app glue: ssh key, host-key pin, rsync push, triggers, calendar-remote.json, Settings › Remote, Mac-side kill switch | Mac | sonnet | 03, calendar work committed | 1 | none to build; a CT to push to (stage 1) |
| 05 | `05-linux-port.md` — `canImport` gates (MCPKit/IndexKit/AIKit), swift-crypto shim, `NoEmbeddingProvider`, Linux CI job | both | sonnet | calendar work committed | 0 | GitHub Actions `ubuntu-24.04` (no Docker on this Mac — verified) |
| 06 | `06-remote-server.md` — `Packages/RemoteServer`: Hummingbird + stateless MCP transport, replica watcher + index rebuild, caps, framing, rate limits, audit log, `audit-replica`, `kill`, PRM metadata + 401 | Linux | sonnet | 05 | 1 | same as 05 |
| 07 | `07-oauth-as.md` — OAuth 2.1 AS: metadata, `/authorize` → Google OIDC → consent → code, `/token` with PKCE + rotation + reuse detection, `/revoke`, bearer validation, auth rate limits; fake-Google tests; `oauth-probe.sh` | Linux | **opus** | 06 | 1 → 2 | same as 05 |
| 08 | `08-container-runbook.md` — scripts + RUNBOOK the user executes: LXC, LUKS, `mp0 backup=0`, users, rrsync key, systemd, nftables + PVE fw, tailscale serve/funnel, timers, build CT | ops | sonnet (writes); **user executes** | 06 binary | 1 → 2 | the Proxmox host — user only |
| 09 | `09-rollout-verification.md` — stage 1–3 check scripts, drills, audit review, docs (FEATURES/README/CLAUDE/PLAN/PROGRESS) | both | sonnet | all | 1 → 3 | — |

Final critique (fable) on 02 and 07 before merge; `notetaker-swift-reviewer`
on 03 and 04.

## Build order and parallelism

```
02 ──► 03 ──► 04 ─────────────────────────┐
05 ──► 06 ──► 07 ──► 08 (user runs) ──► 09 (stages 1–3)
```

- **Start now, zero infrastructure: 02.** It is a pure MarkdownKit value
  type with a fixed test table. 03 follows immediately (VaultKit, temp dirs
  only). 05 can run in parallel with 02 — different packages.
- 02 ∥ 05 → (03 ∥ 06) → (04 ∥ 07) → 08 → 09. Four builders can be busy at
  once at the widest point without touching the same files.
- 08's *scripts* can be written any time after 06's config contract
  (`RemoteConfig` env names, paths, subcommands) is merged; 08's *execution*
  waits for a release binary.

## Prerequisite: the calendar work is uncommitted

`git status` at spec time shows the calendar feature (specs/calendar 02 + 03)
built but not committed: untracked `Packages/CalendarKit/`, `App/Calendar/`,
`App/Services/CalendarSnapshotPublisher.swift`,
`Packages/MCPKit/Sources/MCPKit/VaultCalendar.swift`, and modified
`AppShell.swift`, `SettingsView.swift`, `CalendarService.swift`, MCPKit
sources/tests. Builders work in worktrees branched from HEAD, which will not
contain any of that. Consequences:

- 02 and 03 do not care (MarkdownKit, VaultKit — untouched by the calendar work).
- 04 needs `CalendarService.snapshot`, `CalendarSnapshotPublisher` patterns
  and the Settings calendar pane; 05 and 06 edit MCPKit files the calendar
  work also edits. **Commit the calendar work before starting 04/05/06**
  (overview open question 1).

Pre-existing uncommitted changes on `main` belong to the user; builders
must not revert, reformat, or commit them. `Notetaker 2/3/4/5.xcodeproj`
are iCloud duplicates — ignore.

## File overlap matrix (merge order matters where two specs touch a file)

| file | 02 | 03 | 04 | 05 | 06 | 07 | 09 |
|---|---|---|---|---|---|---|---|
| `Packages/MarkdownKit/Sources/MarkdownKit/ExportPolicy.swift` (new) + tests | **owner** | reads | | | reads (`audit-replica`) | | |
| `Packages/VaultKit/Package.swift` (adds MarkdownKit dep; test dep SecurityKit) | | **owner** | | | | | |
| `Packages/VaultKit/Sources/VaultKit/ReplicaExporter.swift` (new) + tests | | **owner** | reads | | | | |
| `App/Services/RemoteReplicaService.swift` (new) | | | **owner** | | | | |
| `App/Services/VaultIndexService.swift` (one notification post) | | | **owner** | | | | |
| `App/Shell/AppShell.swift` (own + start the service) | | | **owner** | | | | |
| `App/Shell/SettingsView.swift` (new Remote tab) | | | **owner** | | | | |
| `Packages/MCPKit/Sources/MCPKit/VaultFiles.swift`, `VaultLocation.swift` (Darwin gates) | | | | **owner** | | | |
| `Packages/MCPKit/Sources/MCPKit/VaultService.swift` (`isLocked` CRLF hardening; embedding default) | | | | embedding default | `isLocked` | | |
| `Packages/MCPKit/Tests/MCPKitTests/*` (platform gates; CRLF locked test) | | | | gates | +1 test | | |
| `Packages/IndexKit/Package.swift`, `NoteIndexer.swift` (CryptoKit/Crypto shim), +1 FTS5 test | | | | **owner** | | | |
| `Packages/AIKit/Package.swift`, `EmbeddingProvider.swift`, `OllamaProvider.swift` (gates, `NoEmbeddingProvider`) | | | | **owner** | | | |
| `.github/workflows/ci.yml` (linux job) | | | | **owner** (adds job) | adds RemoteServer to the job's list | | |
| `Packages/RemoteServer/**` (new) | | | | | **owner** (Core, HTTP, replica, caps, audit, CLI) | OAuth/, TokenStore/, Auth wiring in `main.swift` | |
| `scripts/remote-vault/*.sh` (new) | | | | | | `oauth-probe.sh` | stage checks, drills, audit summary |
| `deploy/remote-vault/**` (new) | | | | | | | 08 owner |
| `FEATURES.md`, `README.md`, `CLAUDE.md`, `PLAN.md` | | | | | | | **owner** (02–07 add nothing to docs except PROGRESS rows) |
| `PROGRESS.md` (append-only rows) | row | row | row | row | row | row | row |

Everything else is untouched. Specs state "must not change" lists.

## Rules for every builder (restating the design's trust boundary)

1. **No commands against `hildanet` (192.168.5.100) or any CT**, no `pct`,
   no `ssh` to the homelab, no Tailscale configuration, no Funnel. Spec 08
   is a runbook the **user** executes step by step; builders write and
   lint scripts only.
2. **No Google Cloud work.** Builders never create OAuth clients or touch
   the user's Google/Anthropic/Tailscale accounts. Tests use a fake IdP.
3. **No secrets.** Never read `~/.ssh/*`, `~/.claude.json`, `.env`,
   Keychain, or the user's real vault note contents. Acceptance steps that
   look at the user's real export staging dir use **counts only**
   (`grep -c`, `find | wc -l`), never `cat`.
4. **Toolchain + build locations** per CLAUDE.md: `DEVELOPER_DIR=/Applications/Xcode-beta.app`,
   scratch paths under `~/.cache/notetaker-build/<Kit>`, never `build/` or
   `.build/` in the repo. `scripts/verify.sh 3 --install` before every
   commit. Note that `verify.sh` runs `swift test` for **every**
   `Packages/*/` — a new `Packages/RemoteServer` joins the Mac gate
   automatically and must build and test on macOS 26 as well as Linux.
5. **Linux oracle.** This Mac has no Docker/colima/podman (verified). The
   Linux build is verified by the GitHub Actions `linux-packages` job (spec
   05): push the worktree branch and open a draft PR; a green job is the
   evidence. Alternative, user-provided: a throwaway build CT (spec 08 §A).
6. **Worktrees** branch from HEAD; one commit per spec with its PROGRESS.md
   row; `xcodegen generate` + the gate on the merged tree.
7. Formatting: `swiftformat --lint .` is part of the gate; `shellcheck` on
   new shell scripts when installed (`brew list shellcheck`).

## Facts verified while writing these specs (2026-10-29)

- `/usr/bin/rsync` on this Mac is **openrsync** ("rsync version 2.6.9
  compatible", protocol 29); `/opt/homebrew/bin/rsync` is absent. Spec 04
  uses openrsync-safe flags and makes the rsync path a setting; stage 1
  confirms openrsync ↔ `rrsync -wo` compatibility (open question 3 in 04).
- OpenSSH 10.5p1 on the Mac; `ssh-keygen -t ed25519` available.
- Swift 6.4 (Xcode 27 beta). Docker Hub has `swift:6.4-noble` (Ubuntu 24.04)
  — the CI image and the CT toolchain version.
- Upstream releases: Hummingbird **2.28.0**, swift-crypto **5.0.3**, MCP
  swift-sdk **0.12.1** (already pinned), GRDB **7.11.1** (already pinned).
- MCP swift-sdk 0.12.1 ships `StatelessHTTPServerTransport`,
  `HTTPRequest`/`HTTPResponse`, `StandardValidationPipeline`,
  `ProtectedResourceMetadataValidator`, `OAuthProtectedResourceServerMetadata`
  (`Sources/MCP/Base/Transports/HTTPServer/`, `Base/Authorization/`).
- `Frontmatter.split` requires the file to start with `---\n`/`---\r\n` (no
  BOM, no leading blank line) and `VaultService.isLocked` trims with
  `.whitespaces` (which does not strip `\r`). Spec 02 is deliberately
  stricter than both; spec 06 hardens `isLocked`.

## Stages (design §7, with §9 defaults)

- **0 Spikes** — Linux build (CI job, spec 05); FTS5 presence (IndexKit
  test); openrsync↔rrsync (user, after the CT exists); Google accepting a
  `.ts.net` redirect (user, when creating the OAuth client); forwarded-IP
  header (observed in the audit log at stage 2).
- **1 Tailnet-only** — CT provisioned (08), binary behind `tailscale serve`,
  `ALLOW_LOOPBACK=1`, OAuth exercised with `oauth-probe.sh` + MCP Inspector
  (+ Claude Code if its installed version accepts a pre-registered client
  ID — unverified), exporter pushing from the Mac, exclusion tests green,
  `audit-replica` run, audit log reviewed.
- **2 Funnel** — `ALLOW_LOOPBACK=0`, Funnel on (user), custom connector in
  claude.ai web, then phone. Anthropic IP allowlist stays off unless the
  audit log shows a real client IP.
- **3 Drills** — both kill switches, refresh-token reuse, vzdump archive
  contains no note text, one week of audit review, then default-on.

## Open questions for the user

1. **Calendar work is uncommitted** (see Prerequisite). (a) commit it first
   as its own pass, then start 04/05/06 *(recommended)*; (b) start only
   02/03 now and decide later.
2. **Linux build oracle.** (a) GitHub Actions only — builders push draft
   PRs *(spec default)*; (b) install Docker Desktop or colima on the Mac
   (arm64 Linux; catches portability issues but not x86_64-specific ones);
   (c) you provision a throwaway build CT and grant builders SSH to that CT
   only.
3. **Client secret in addition to PKCE?** (a) public client, PKCE only
   *(spec 07 default; matches design §4.4)*; (b) also a client secret
   pasted into the connector dialog — only if stage 1 confirms claude.ai
   sends it (`client_secret_post`/`basic`); spec 07 leaves a documented
   hook.
4. **Scope levers in v1.** Spec 02 implements `excludedFolders` and a
   `remote: false` frontmatter opt-out (design §6 "needs no redesign") and
   spec 04 exposes them in Settings. (a) keep *(default)*; (b) drop for a
   smaller v1.

None of these block 02, 03, or 05.

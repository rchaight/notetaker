# 00 — Server-side vault backup: restic to B2 from the replica (CT 122)

Status: SPEC, 2026-10-31. Source plan: `~/.claude/plans/idempotent-conjuring-bear.md`, **superseded by the user's design change of 2026-10-31** wherever the two conflict: nothing in the backup may depend on the Mac. This file is the build contract; the plan file is history. Facts marked **[verified]** were read from code or deploy files in this session; **[unverified]** must be confirmed by the orchestrator on the host (§6) before the step that relies on them.

Design in one paragraph: a new unprivileged LXC **CT 122 `vault-backup`** on hildanet gets the remote-vault **replica inbox** (`/mnt/notetaker-replica/srv/inbox` on the host, the LUKS volume CT 120 already uses) bind-mounted **read-only**, and runs `restic backup` of it nightly to the existing B2 bucket under a **new repository path `vault-replica`**, with a new restic password and a new append-only B2 key that exist only on CT 122. No Mac job, no new LUKS volume, no new access for CT 120, no inbound network to CT 122. The replica is the filtered copy the Mac already pushes (`ExportPolicy`-gated), so the backup inherits its filter, see §1.

## 0. What changed against the plan file (decision record)

| Plan file said | Now | Why |
|---|---|---|
| Mac pushes the raw full vault (`vault-push.sh`, LaunchAgent 03:15, dedicated ssh keys, LAN IP allowlist) | **No Mac-side component at all.** Source = the replica inbox on the host's LUKS volume. | The Mac is not always on or on the network; a backup that needs it is not a backup. |
| New 15 GB LUKS volume `pve/nr-vaultcopy` holding a plaintext copy of the full vault, locked notes included | **No new volume, no plaintext full copy.** CT 122 reads the existing replica volume read-only. | Removes the documented "relaxation" entirely; what is not in the replica is not in the backup (§1). |
| rsync gate with a 20 % file-count drop guard on the push | **Source guards in the restic wrapper** (DISABLED marker, manifest, count floor, 20 % drop vs last success, digest check). | Same intent, applied where the data is read. |
| Reuse the old repo path `vault`, `--host notetaker-mac --tag notetaker-vault`, rotate the Mac's daily key at the end | **New repo path `vault-replica`, `--host nr-replica --tag notetaker-replica`, new password, new daily key.** The legacy repo, its snapshots, the Mac's Keychain items and LaunchAgent stay as they are until the user retires them. | The two repos hold different data (full vault vs filtered replica); mixing them in one repo would make "latest" ambiguous. |
| Two builders (server + Mac) | **One builder**, `deploy/vault-backup/**` + this spec's test harness. | No Mac side left. |

## 1. Scope and the coverage gap (read this first)

**This backup covers exactly what the replica holds and nothing more.** The replica is built by `VaultKit.ReplicaExporter` under `MarkdownKit.ExportPolicy` **[verified: ReplicaExporter.swift, design 00 §5]**, which by design excludes:

- **locked notes** (`locked: true`, locked envelopes, unclosed frontmatter with a lock key);
- `_index.md` at any depth, hidden/dot files, `.icloud` placeholders and dataless files;
- every **non-`.md`** file (attachments, images, PDFs);
- files over the exporter's size cap, symlinks, hard-linked files, name collisions;
- any folder in Settings › Remote › **Excluded folders** (currently at least `private`), and notes with `remote: false`.

**Those files have no server-side backup after this change. Their only copies remain iCloud and Time Machine.** The legacy Mac job (`scripts/backup/vault-backup.sh`, repo path `vault`) did cover them; its existing snapshots stay in B2 untouched (§7), and whether to keep running it is a later user decision, not part of this work. The README (§4.1) and the threat notes (§7, item 1) state this gap in the same words.

The backup is also **only as fresh as the last push**: the Mac pushes on change and on a 5-minute timer while awake; if it is off for days the replica, and therefore the snapshot, is days old. That is accepted and surfaced as a warning, not a failure (§5.3).

In scope: everything under `deploy/vault-backup/` (CT provisioning, the restic wrapper, systemd units, firewall, host-side check units, local test harness, README) and this spec. Out of scope: §9.

## 2. Architecture

```
hildanet (Proxmox 9.2.5)                                  Internet
 /etc/notetaker-replica/luks.key ──► notetaker-replica-unlock.service (Before=pve-guests)
   └─ LUKS pve/nr-replica ──► /mnt/notetaker-replica/srv/{inbox,state}
        │                                   │
        │ mp0 rw, backup=0 (unchanged)      │ mp0 ro=1, backup=0  (NEW; inbox only, never state/)
        ▼                                   ▼
   CT 120 notetaker-remote             CT 122 vault-backup (unprivileged, no Tailscale,
   /srv/replica/{inbox,state}          no sshd, nftables: out = DNS/NTP/443 only)
   (Mac pushes here via ssh gate)      /srv/replica-ro/{vault/,manifest.json,calendar-remote.json|DISABLED}
                                          vault-backup.timer 04:10 ─► vault-restic-backup run
                                            guards: DISABLED? manifest? count ≥ 100? drop ≤ 20 %? digest ok?
                                            restic backup --host nr-replica --tag notetaker-replica ──► B2 bucket <BUCKET>, path vault-replica/
                                          /etc/vault-backup/env (root 0400): daily B2 key (append-only, prefix vault-replica/), restic password
                                          /var/lib/vault-backup/{last-success,last-run,last-failure,lock}
   host: notetaker-vaultbackup-check.timer 06:30 ─► pct exec 122 -- vault-restic-backup verify-last
         OnFailure ─► notetaker-vaultbackup-check-failed.service ─► mail root ─► PVE notification (gmail), same path as pve-offsite-backup-failed
```

Trust facts the design relies on:

- The replica volume is opened by the host before any guest starts **[verified: host/notetaker-replica-unlock.service, `Before=pve-guests.service`]**; while locked, `/mnt/notetaker-replica/srv` does not exist and the mount point is immutable, so `pct start 122` fails exactly like `pct start 120` **[verified for CT 120: PROGRESS row 218, drill 3.3]**. CT 122 gets **no new unlock unit**; it rides the existing ordering.
- The inbox is written only by CT 120's `replica` user through the forced-command gate, as 0644 files in 2750 `replica:notetaker` directories **[verified: ct/setup.sh, PROGRESS 216]**. CT 122's root reads them inside its own user namespace (same default idmap base 100000 **[unverified: confirm `lxc.idmap` is absent from both `/etc/pve/lxc/120.conf` and `122.conf`]**), so the service runs as root with `CAP_DAC_READ_SEARCH` and nothing else (§4.5).
- `pct set -mp0 <hostdir>,mp=<ctdir>,ro=1,backup=0` mounts a host directory read-only into an unprivileged CT **[unverified on PVE 9.2.5; §6 step 2 proves it with `findmnt` and an `EROFS` touch]**.
- The manifest format **[verified: ReplicaExporter.swift]**: JSON, sorted keys, ISO-8601 `generatedAt`; keys `schemaVersion` (1), `disabled`, `noteCount`, `files[]` of `{path, sha256, bytes}` with `path` relative to `vault/`, `filesDigest` = hex SHA-256 over the concatenation, in `files` order, of `"<utf8 byte length of path>:<path>\n<sha256>\n"`; `calendarIncluded`, `appVersion`, the four excluded counts. The kill-switch image is `DISABLED` (empty file) + a manifest with `disabled: true, noteCount: 0`; `nr-kill` leaves only `DISABLED` (no manifest) **[verified: ct/nr-kill]**.

## 3. Fixed names and interfaces (the builder uses these verbatim)

| Item | Value |
|---|---|
| CT id / hostname / IP | `122` / `vault-backup` / `<CT122_IP>` (static, same bridge and gateway as CT 120, `firewall=1` on net0, `--nameserver 1.1.1.1`) |
| CT resources | unprivileged, `nesting=0`, **no** `dev0` (no tun), 2 cores, 2048 MB RAM, 512 MB swap, rootfs `local-lvm:8`, `onboot 1` |
| Mount | `mp0: /mnt/notetaker-replica/srv/inbox,mp=/srv/replica-ro,ro=1,backup=0` (inbox only: `state/` with tokens and index is never visible to CT 122) |
| Source dir in CT | `/srv/replica-ro` (`SRC` in the wrapper; override `VAULT_BACKUP_SOURCE` for tests only) |
| Backup set | `restic backup --host nr-replica --tag notetaker-replica --exclude /srv/replica-ro/calendar-remote.json /srv/replica-ro` (notes + `manifest.json`; the calendar snapshot is derived from EventKit and is not backed up) |
| Repository | `RESTIC_REPOSITORY=b2:<BUCKET>:vault-replica` (same bucket as the legacy `vault` path, new path, new password) |
| Env file | `/etc/vault-backup/env`, root 0400, systemd `EnvironmentFile` syntax: `RESTIC_REPOSITORY`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`, `RESTIC_PASSWORD`, `RESTIC_CACHE_DIR=/var/cache/vault-backup` |
| State dir | `/var/lib/vault-backup/` root 0700: `last-success`, `last-run`, `last-failure`, `accept-shrink`, `lock` |
| Log | `/var/log/vault-backup/backup.log` root 0600, trimmed to the last 2000 lines once over 1 MiB (same rule as `scripts/backup/vault-backup.sh`) |
| Restore scratch | `/run/vault-backup/restore` (tmpfs, RAM only; the wrapper refuses a non-tmpfs `/run` unless `VAULT_BACKUP_ALLOW_DISK_TMP=1`, test harness only) |
| Timer | `vault-backup.timer`: `OnCalendar=*-*-* 04:10:00`, `Persistent=true`, `RandomizedDelaySec=0` (after the 02:00 vzdump and the 03:15+15 m offsite job) |
| Host check | `notetaker-vaultbackup-check.timer` 06:30 daily → `pct exec 122 -- /usr/local/sbin/vault-restic-backup verify-last`; `OnFailure=notetaker-vaultbackup-check-failed.service` |
| Wrapper exit codes | 0 ok (incl. `warn`), 1 failure, 2 usage, 3 restic exit 3 (snapshot made, unreadable files), 4 **source guard refused** (no snapshot), 5 lock held |
| `last-run` line | `<ok|warn|skip|fail> <ISO-8601 UTC> <code> <message>` — one line, overwritten each run; `message` is a fixed string plus numbers, **never a path or note name** (it is mailed) |
| `last-success` line | `count=<N> generated_at=<manifest generatedAt> snapshot=<short id> at=<ISO-8601 UTC>` — written only after restic exit 0 |
| B2 daily key | capabilities exactly `listBuckets listFiles readFiles writeFiles`, bucket-restricted, **name prefix `vault-replica/`** (so it cannot even list the legacy repo) |

Placeholders the orchestrator fills at rollout: `<CT122_IP>`, `<BUCKET>`, `<BRIDGE>`, `<GATEWAY>`, `<TEMPLATE>`.

## 4. Build task (one builder, `deploy/vault-backup/**` only)

General acceptance for every shell file: `#!/usr/bin/env bash`, `set -euo pipefail` (except where a unit's semantics need otherwise, say so in a comment), `shellcheck` clean (`brew install shellcheck` on the Mac if missing) and `bash -n` clean; no secret is ever read, echoed, logged or committed; every script that can change the system prints a plan without `--yes` and is idempotent with it (pattern: `deploy/remote-vault/ct/setup.sh` **[verified]**). Match that tree's style: header comment with install path and usage, `die`/`say`/`install_file` helpers, `install -D -m`.

### 4.1 `deploy/vault-backup/README.md`

Operator document in the voice of `scripts/backup/README.md`. Must contain, in this order: (a) **the coverage gap of §1 in its own first section**, naming locked notes, `_index.md`, hidden files, non-`.md` files, excluded folders and `remote: false`, and the sentence "Their only copies remain iCloud and Time Machine"; (b) the architecture summary and the fixed names table of §3; (c) what each guard refuses and what the operator sees (`last-run` codes, the `accept-shrink` override); (d) the kill-switch paragraph of §7 item 6 verbatim; (e) B2 setup for the new key and repo (new daily key with the prefix, `openssl rand -base64 33` for the password, password into the password manager too, `restic init` with the admin key typed into a `read -rs` shell with `unset HISTFILE`, never into the env file); (f) monthly maintenance by hand on CT 122 (`pct enter 122`, admin key via `read -rs`, `unlock`, `forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune`, `check --read-data-subset=5%`, `unset`), with the same "do not prove append-only with `forget`" and "Keep all versions" warnings as the legacy README; (g) restore: `restore-test` and real recovery (`restic restore latest --host nr-replica --tag notetaker-replica --target <dir> --include <path>`; restic recreates `/srv/replica-ro/...` under the target); (h) the legacy job: a short section saying the Mac job and its repo path `vault` are untouched by this and that retiring them is a separate decision. Acceptance: every path, unit name, exit code and flag in the README appears identically in the files below (the orchestrator greps them).

### 4.2 `deploy/vault-backup/ct/setup.sh`

Provisions CT 122 from inside the CT as root; single phase (no Tailscale, no key exchange). `bash setup.sh` prints the plan and changes nothing; `bash setup.sh --yes` does, idempotently:

1. Refuses unless Ubuntu 24.04, root, and **`mountpoint -q /srv/replica-ro` and `findmnt -no OPTIONS /srv/replica-ro` contains `ro`** (die with the exact message "`/srv/replica-ro` is not a read-only mount point: finish the host steps (spec §6 step 1) first").
2. Opens the apt window with `vb-maint on 20` if the firewall table already exists (trap `vb-maint off`), then `apt-get install -y --no-install-recommends restic nftables python3 ca-certificates`. Prints `restic version` (Ubuntu 24.04 ships 0.16.x **[unverified]**; record it in PROGRESS; the wrapper must not use flags newer than 0.16: no `--skip-if-unchanged`, no `--no-scan`).
3. Directories: `/etc/vault-backup` (root 0700), `/var/lib/vault-backup` (root 0700), `/var/cache/vault-backup` (root 0700), `/var/log/vault-backup` (root 0700). Env from `env.example` **only if absent**, root 0400; never overwrite an existing env.
4. Installs `vault-restic-backup` → `/usr/local/sbin/` 0750, `manifest-check.py` → `/usr/local/lib/vault-backup/manifest-check.py` 0644, `vb-maint` → `/usr/local/sbin/vb-maint` 0750, the three units → `/etc/systemd/system/`, `daemon-reload`, `systemctl enable vault-backup.timer` (the timer is **enabled but the service is not started**: the first run is the orchestrator's step with the user present). Prints the timer's next elapse.
5. Firewall: `nft -c -f` the rendered `nftables.conf`, install to `/etc/nftables.conf`, `systemctl enable nftables`, `nft -f /etc/nftables.conf` (never `systemctl restart nftables`: its stop path flushes the ruleset, same reason as CT 120). No placeholders to fill: the policy has no inbound.
6. Ends by printing `systemd-analyze security vault-backup.service` (record the score) and `vault-restic-backup status`.

Acceptance: running `--yes` twice prints `unchanged:` for every file on the second run; no step reads the env file's contents; `grep -c 'B2_ACCOUNT_KEY\|RESTIC_PASSWORD' setup.sh` is 0.

### 4.3 `deploy/vault-backup/ct/vault-restic-backup`

The wrapper, a port of `scripts/backup/vault-backup.sh` **[verified]** with the Keychain replaced by the env file and the Mac guards replaced by the source guards of §5. Subcommands: `run` (default), `check`, `snapshots`, `restore-test`, `status`, `verify-last`, `accept-shrink`. Behaviour is specified in §5; acceptance is the test table in §4.9. Requirements beyond §5:

- Secrets: the env file is sourced only inside the subshell that `exec`s restic (as `restic_cmd` does today); the wrapper never `export`s them in its own process, never logs argv, and refuses to run `run`/`check`/`snapshots`/`restore-test` if the env file is missing, not mode 0400, or still contains `<`-bracketed placeholders (fixed message, exit 1).
- Test hooks (env, all optional): `VAULT_BACKUP_ENV` (env file path), `VAULT_BACKUP_SOURCE`, `VAULT_BACKUP_STATE`, `VAULT_BACKUP_LOG`, `VAULT_BACKUP_CACHE`, `VAULT_BACKUP_ALLOW_DISK_TMP=1`, `VAULT_BACKUP_NOW` (ISO-8601, overrides "now" for the staleness and 26 h checks), `VAULT_MIN_NOTES` (default 100). A local-path `RESTIC_REPOSITORY` in the env file works unchanged (restic needs no B2 variables then).
- Logging: `log()` appends `YYYY-MM-DD HH:MM:SS <text>` to the log and prints `<text>` to stderr; restic's own output goes **only** to the log file (it can name note paths); stderr/journal lines are fixed strings plus numbers.
- Lock: `exec 9>"$STATE/lock"; flock -n 9 || { log "another run is in progress"; exit 5; }` for `run` and `restore-test`.
- `run` on restic exit 3 logs "backup finished with unreadable files (exit 3)", writes `last-run fail 3`, exits 3 (a read-only bind should never have unreadable files; this is a failure to investigate, not the Mac's offline-iCloud case).
- `restore-test`: `restic restore latest --no-lock --host nr-replica --tag notetaker-replica --path /srv/replica-ro --target "$TMP"`, then `diff -rq -x calendar-remote.json -x DISABLED "$SRC" "$TMP$SRC"`; PASS/FAIL line as today; the tmp dir is on tmpfs (§3), created 0700, `rm -rf` on exit via trap after `chmod -R u+w`. Refuses to start if `df --output=avail` of the tmpfs is less than (sum of `bytes` in the manifest + 32 MiB), with the message "raise CT 122 memory".
- `status`: prints source path, mount options, DISABLED present?, manifest `generatedAt`/`noteCount`/`disabled`, on-disk `.md` count, `last-success`, `last-run`, timer next elapse. Reads no secrets.
- `verify-last` (used by the host check; **no restic call, no network**): exit 0 if `last-run` starts with `ok` and its timestamp is less than 26 h before now; exit 2 if it starts with `warn` (stale replica); otherwise exit 1 (`skip`, `fail`, missing file, or older than 26 h). Prints the `last-run` line and, when present, the first 20 lines of `last-failure`.
- `accept-shrink`: `touch "$STATE/accept-shrink"` and print what it does (the next `run` may go below the 20 % floor once; the file is removed by that run whether or not it was needed).

### 4.4 `deploy/vault-backup/ct/manifest-check.py`

Python 3 standard library only, invoked by the wrapper as `python3 -I manifest-check.py <inbox dir>`; prints exactly one line on stdout and exits 0 on success: `ok count=<N> generated_at=<ISO> bytes=<sum> digest=<hex>` (digest = the manifest's `filesDigest`; added after critic round 2). Exits 4 with a one-line reason on stdout (`reason=<fixed token>`) for: `DISABLED` present (checked **first**, regardless of the manifest), manifest missing, not valid JSON, `schemaVersion != 1`, `disabled` true, `noteCount != len(files)`, any entry path that is absolute, contains `..`, or has a component that is a symlink, an entry missing on disk, size mismatch, SHA-256 mismatch, a `.md` file under `vault/` that is not in the manifest (stray), a non-regular file under `vault/`, or a recomputed `filesDigest` that differs from the manifest's. It never follows symlinks (`os.lstat`), reads every file in binary, and takes less than 60 s for 2 000 notes on the CT (acceptance measured in §6 step 5). Reason tokens are fixed identifiers (`disabled_marker`, `manifest_missing`, `manifest_invalid`, `manifest_disabled`, `count_mismatch`, `entry_missing`, `entry_size`, `entry_sha256`, `stray_file`, `not_regular`, `bad_path`, `digest_mismatch`); no path ever appears on stdout (paths go to stderr, which the wrapper sends to the log only).

### 4.5 `deploy/vault-backup/ct/vault-backup.service`, `vault-backup.timer`, `vault-backup-failed.service`

- Service: `Type=oneshot`, `User=root`, `EnvironmentFile=/etc/vault-backup/env`, `ExecStart=/usr/local/sbin/vault-restic-backup run`, `OnFailure=vault-backup-failed.service`, `SuccessExitStatus=` empty (exit 3 and 4 are failures so the host sees them), `TimeoutStartSec=2h`. Hardening, in this order and verbatim: `ProtectSystem=strict ProtectHome=yes PrivateTmp=yes NoNewPrivileges=yes CapabilityBoundingSet=CAP_DAC_READ_SEARCH RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX SystemCallFilter=@system-service LockPersonality=yes ProtectKernelTunables=yes ProtectKernelModules=yes ProtectKernelLogs=yes RestrictNamespaces=yes UMask=0077 ReadOnlyPaths=/srv/replica-ro ReadWritePaths=/var/lib/vault-backup /var/cache/vault-backup /var/log/vault-backup RuntimeDirectory=vault-backup RuntimeDirectoryMode=0700`. `MemoryDenyWriteExecute` is **omitted** (Go runtime; add only if a run on the CT proves restic tolerates it). `RequiresMountsFor=/srv/replica-ro`. Note that `EnvironmentFile` means the secrets are in the service's environment; the wrapper still must not print `env`.
- Timer: §3; `[Install] WantedBy=timers.target`.
- Failed unit: `Type=oneshot`, `ExecStart=/bin/sh -c 'journalctl -u vault-backup.service -n 40 --no-pager > /var/lib/vault-backup/last-failure'` (the file is what `verify-last` shows and the host mails; because the wrapper's stderr holds no paths, neither does this file).

Acceptance: `systemd-analyze verify` on all three passes (run on the CT by the orchestrator; the builder checks syntax by eye and with `systemd-analyze verify` if a Linux box is handy, otherwise says so).

### 4.6 `deploy/vault-backup/ct/nftables.conf` and `ct/vb-maint`

Clone of `deploy/remote-vault/ct/nftables.conf` and `nr-maint` with table name `inet vaultbackup` and **no inbound rules at all** (input: `lo`, invalid drop, established/related, IPv6 drop, policy drop: there is no sshd), no Tailscale rules, no `<DNS_UIDS>` (DNS: udp/tcp 53 to non-RFC1918 for any user, since the CT's resolver is 1.1.1.1), NTP udp 123, TCP 443 to non-RFC1918 (B2 API and download hosts), the kernel-expiring `maint` set for TCP 80 (apt). **No egress to RFC1918 ever** (CT 122 cannot reach the Mac, the host, or CT 120). Header comment lists each rule and why. `vb-maint` is `nr-maint` with the table name changed. Acceptance: `nft -c -f` passes on the CT; the §6 isolation checks (`curl` to 192.168.5.100:8006 blocked, `getent hosts api.backblazeb2.com` resolves, `curl -sI https://api.backblazeb2.com` reaches 443).

### 4.7 `deploy/vault-backup/ct/env.example`

Same layout as `deploy/remote-vault/ct/env.example`: header (root 0400, never commit a filled copy, no quotes, no `export`), the five keys of §3 with `<PLACEHOLDER>` values, and a comment per key saying who creates it (daily key: B2 console with the four capabilities and the prefix; password: `openssl rand -base64 33`, also in the password manager; repository: `b2:<BUCKET>:vault-replica`). Acceptance: `grep -c '^[A-Z0-9_]*=' env.example` is 5; every value except the fixed `RESTIC_CACHE_DIR` contains `<` (amended after critic round 1).

### 4.8 `deploy/vault-backup/host/`

- `pve-firewall.122.fw.example`: `[OPTIONS]` as CT 120's example (`policy_in: DROP`, logging, `macfilter: 1`), **`[RULES]` empty** with a comment that admin access is `pct enter 122` only.
- `notetaker-vaultbackup-check.service`: `Type=oneshot`, `ExecStart=/usr/sbin/pct exec 122 -- /usr/local/sbin/vault-restic-backup verify-last`, `OnFailure=notetaker-vaultbackup-check-failed.service`. `notetaker-vaultbackup-check.timer`: `OnCalendar=*-*-* 06:30:00`, `Persistent=true`. `notetaker-vaultbackup-check-failed.service`: `Type=oneshot`, `ExecStart=/bin/sh -c 'journalctl -u notetaker-vaultbackup-check.service -n 40 --no-pager | mail -s "hildanet: Notetaker replica backup needs attention" root'`. Header comment: "mirrors `pve-offsite-backup-failed.service`; the orchestrator compares the two at install time and adjusts the subject/pipe to match the live unit" (the builder cannot read the host unit; the host's `mail` → `/etc/aliases` → PVE notification path is **[verified: memory, 2026-07-31]**). `verify-last` exit 2 (stale replica) is a failure of this unit by design: that is how "alert, not fail" reaches the inbox without failing the backup itself.

### 4.9 `deploy/vault-backup/test/`

`make-fixture.py` (stdlib; builds an inbox directory with N notes under `vault/`, nested folders, UTF-8 names, and a manifest written with the §2 digest formula, sorted keys, ISO-8601 `generatedAt`; options `--notes N --generated-at ISO --disabled --corrupt {digest,size,sha,stray,missing,count}`) and `run-local.sh`, which needs only `bash`, `python3`, `restic` on PATH and a scratch dir (`--scratch DIR`, default under `$TMPDIR`; **never inside the repo**), creates a local restic repo (`restic init` with a throwaway password in a test env file, mode 0400), and runs the table below against the wrapper with the §4.3 hooks, printing one `PASS`/`FAIL` line per case and exiting non-zero on any `FAIL`. Cases (expected wrapper exit code / `last-run` code):

| # | Setup | Expect |
|---|---|---|
| 1 | 120 notes, fresh manifest | `run` → 0 / `ok`; `last-success` has `count=120`; `restic snapshots` shows host `nr-replica`, tag `notetaker-replica`, path `<SRC>` |
| 2 | second `run`, nothing changed | 0 / `ok`; log line contains `Added to the repository: 0 B` or restic's equivalent (dedup) |
| 3 | `DISABLED` present (manifest also present, `disabled: true`) | 4 / `skip disabled_marker`; snapshot count unchanged |
| 4 | `DISABLED` only, no manifest (nr-kill image) | 4 / `skip disabled_marker` |
| 5 | manifest missing | 4 / `skip manifest_missing` |
| 6 | corrupt digest / size / sha / stray / missing / count (six runs) | 4 each, matching reason token |
| 7 | 80 notes (below floor 100) | 4 / `skip below_floor` |
| 8 | 120 → 90 notes with valid manifest (25 % drop) | 4 / `skip shrink`; then `accept-shrink` + `run` → 0 / `ok`; `accept-shrink` file gone |
| 9 | 120 → 100 notes (16.7 % drop) | 0 / `ok` |
| 10 | manifest `generatedAt` 8 days before `VAULT_BACKUP_NOW` | 0 / `warn stale`; a snapshot **is** made |
| 11 | `restore-test` after case 1 | 0, prints `PASS`; scratch dir removed |
| 12 | modify one note after the last run, `restore-test` | 1, prints `FAIL` |
| 13 | hold the lock (`flock` in background), `run` | 5 |
| 14 | env file with a `<PLACEHOLDER>` left | 1, no restic call (repo snapshot count unchanged) |
| 15 | `verify-last` after case 1 with `VAULT_BACKUP_NOW` = +25 h | 0; at +27 h → 1; after case 10 → 2 |
| 16 | `manifest-check.py` on 2 000 generated notes | exits 0 in under 60 s on the Mac |

The harness runs on macOS with Homebrew restic (0.18.x **[verified: `/opt/homebrew/bin/restic` exists]**) and on Linux; `VAULT_BACKUP_ALLOW_DISK_TMP=1` is set by the harness only.

### 4.10 Not in the builder's tree

The builder does **not** edit `scripts/backup/*`, `deploy/remote-vault/*`, `CLAUDE.md`, `PROGRESS.md`, `specs/remote-vault/*`, `deploy/remote-vault/site/*` or any Swift file. Those edits are orchestrator steps after cutover (§6 step 9).

## 5. Wrapper semantics (`run`)

Order is fixed; the first failing guard wins and nothing after it executes.

1. Lock (§4.3). Trim the log.
2. Env preflight: file present, 0400, no placeholders, `restic` on PATH.
3. Source preflight: `SRC` is a mount point whose options contain `ro` (skip this when `VAULT_BACKUP_SOURCE` is set); otherwise `fail source_not_ro`, exit 1. Never back up a writable or absent source.
4. `manifest-check.py "$SRC"` → on exit 4, write `last-run skip <reason>` and exit 4. This covers the DISABLED marker (Mac toggle off, `nr-kill`), a missing or half-pushed manifest, digest mismatch and strays.
5. Floor: `count < VAULT_MIN_NOTES` (100) → `skip below_floor`, exit 4.
6. Shrink guard: read `count=L` from `last-success`; if present and `L >= 100` and `count * 5 < L * 4` and `accept-shrink` is absent → `skip shrink` (message includes both numbers), exit 4. Remove `accept-shrink` if present (consumed) before continuing.
7. Staleness: `generated_at` older than 7 × 24 h before now → remember `warn stale` (does not stop the run).
8. `restic backup` (§3 command). Exit 0 → **post-check (added after critic round 1, closes the race with a push landing mid-backup):** re-run `manifest-check.py`; if it fails or its `count`, `bytes` or `digest` differ from step 4 (**not** `generated_at`: the Mac re-pushes a fresh manifest with a new `generatedAt` and identical content every 300 s while awake, which must not raise a warning), write `last-run warn 0 concurrent_push`, leave `last-success` untouched, exit 0 (the host check mails `warn`; the next run supersedes the snapshot). Otherwise write `last-success`, then `last-run ok` (or `warn stale`), exit 0. Exit 3 → `last-run fail 3`, exit 3. Other → `last-run fail <rc>`, exit 1.

Kill-switch invariant (restated for the builder): with the inbox in either kill image, steps 4 and 5 both refuse, so **no snapshot of an empty or tiny replica is ever created**, and `last-success` keeps the previous count so the next real push is compared against it.

## 6. Host and Proxmox runbook (orchestrator runs it over SSH as root on hildanet, one step at a time, a user gate at every step marked ⏸)

Pre-flight (user supplies): `<CT122_IP>` unused on the LAN (`ping -c2` fails, not in the UniFi client list); `<BUCKET>` (the existing private bucket, SSE-B2, "Keep all versions"); B2 console access; a password manager entry ready for the new restic password. Orchestrator records before starting: `pct config 120 > /root/pct120.before`, `systemctl is-active notetaker-replica-unlock`, `notetaker-replica-unlock status` (unlocked), `pvesh get /cluster/backup --output-format json | grep -o '"vmid":"[^"]*"'` (122 absent), `grep -n notetaker-replica /usr/local/sbin/pve-offsite-backup.sh` (the existing exclude line; **nothing new is added**: there is no new key).

1. ⏸ **[host] Create CT 122** (nothing started): `pct create 122 local:vztmpl/<TEMPLATE> --hostname vault-backup --unprivileged 1 --features nesting=0 --cores 2 --memory 2048 --swap 512 --rootfs local-lvm:8 --onboot 1 --net0 name=eth0,bridge=<BRIDGE>,ip=<CT122_IP>/24,gw=<GATEWAY>,firewall=1 --nameserver 1.1.1.1`; `pct set 122 -mp0 /mnt/notetaker-replica/srv/inbox,mp=/srv/replica-ro,ro=1,backup=0`; `install -m 0644 /root/vb-deploy/host/pve-firewall.122.fw.example /etc/pve/firewall/122.fw`. Expect in `/etc/pve/lxc/122.conf`: `mp0: /mnt/notetaker-replica/srv/inbox,mp=/srv/replica-ro,ro=1,backup=0`, no `dev0`, `unprivileged: 1`, no `lxc.idmap` line; `diff /root/pct120.before <(pct config 120)` empty.
2. **[host] Start and prove the mount**: `pct start 122`; `pct exec 122 -- findmnt -no OPTIONS,SOURCE /srv/replica-ro` shows `ro`; `pct exec 122 -- sh -c 'touch /srv/replica-ro/x'` fails with "Read-only file system"; `pct exec 122 -- ls /srv/replica-ro` lists `vault manifest.json` (+ `calendar-remote.json`); `pct exec 122 -- sh -c 'find /srv/replica-ro -type f ! -readable | wc -l'` prints 0; `pct exec 122 -- ls /srv/replica-ro/../` must not reveal `state` (the bind is the inbox only). Stop-and-ask if `ro=1` is rejected or the touch succeeds.
3. ⏸ **[host] Fail-closed drill** (takes the remote vault down for about a minute): `pct stop 122; pct stop 120; systemctl stop notetaker-replica-unlock; pct start 122` must **fail**; `systemctl start notetaker-replica-unlock; pct start 120; pct start 122` succeed; `pct exec 120 -- systemctl is-active notetaker-remote tailscaled` active; from the Mac, Settings › Remote shows the replica ready. Stop-and-ask if CT 122 started while locked.
4. **[host → ct] Provision**: `scp -r deploy/vault-backup root@192.168.5.100:/root/vb-deploy` (no secrets in it), `tar -C /root/vb-deploy -czf /root/vb.tgz ct && pct push 122 /root/vb.tgz /root/vb.tgz`, `pct enter 122`, untar, `bash setup.sh` (plan), `bash setup.sh --yes`. Expect the mount check to pass, restic version printed, `vault-backup.timer` enabled with next elapse 04:10, `systemd-analyze security vault-backup.service` recorded, nftables loaded; `curl -sS -m 5 http://192.168.5.100:8006 || echo blocked` → blocked; `curl -sSI -m 8 https://api.backblazeb2.com | head -1` → an HTTP status line. Remove `/root/vb.tgz` on the host afterwards (the offsite tar covers `/root`).
5. ⏸ **[user, ct] Secrets** (orchestrator steps out; nothing typed in chat): B2 console → new application key, bucket `<BUCKET>`, capabilities `listBuckets listFiles readFiles writeFiles`, **name prefix `vault-replica/`**; `pct enter 122; unset HISTFILE; openssl rand -base64 33` → password manager; `nano /etc/vault-backup/env` (five values); `ls -l /etc/vault-backup/env` → `-r-------- root root`; then with the **admin** key in a `read -rs` shell: `restic -r b2:<BUCKET>:vault-replica init`, `unset` the variables, `exit`. Orchestrator then runs `pct exec 122 -- vault-restic-backup status` (no secrets printed) and `time pct exec 122 -- python3 -I /usr/local/lib/vault-backup/manifest-check.py /srv/replica-ro` → `ok count=<N> ...` in under 60 s with `<N>` equal to Settings › Remote "Notes exported" (1807 at the time of writing **[verified: PROGRESS 217]**). This is the proof that the digest formula was ported correctly; a `digest_mismatch` here is a builder bug, not a replica problem.
6. ⏸ **[ct] First run**: `pct exec 122 -- vault-restic-backup run` → exit 0; `snapshots` shows one snapshot, host `nr-replica`, tag `notetaker-replica`, path `/srv/replica-ro`; second `run` → `Added to the repository` small; `restore-test` → `PASS`. If the first run exits 3 with "operation not permitted", the cause is restic's `O_NOATIME` open needing `CAP_FOWNER` on foreign-uid files (not the mount): add `CAP_FOWNER` to `CapabilityBoundingSet` and rerun. Record snapshot id, file count, bytes, duration, `last-success` line in PROGRESS. In the B2 console confirm objects appear only under `vault-replica/`.
7. **[host] Check units**: compare `systemctl cat pve-offsite-backup-failed.service` with `host/notetaker-vaultbackup-check-failed.service` and align the `mail` invocation; `install -m 0644 host/notetaker-vaultbackup-check*.{service,timer} /etc/systemd/system/`; `daemon-reload`; `systemctl enable --now notetaker-vaultbackup-check.timer`; `systemctl start notetaker-vaultbackup-check.service` → success. ⏸ Induced failure: `pct exec 122 -- mv /var/lib/vault-backup/last-run /var/lib/vault-backup/last-run.bak`; `systemctl start notetaker-vaultbackup-check.service` fails; the user confirms the mail arrived; restore the file; `systemctl start` succeeds again.
8. ⏸ **Drills** (each gets a PROGRESS row with observed output):
   - **Kill switch**: Mac Settings › Remote toggle off → `pct exec 122 -- vault-restic-backup run` → exit 4, `last-run skip disabled_marker`, snapshot count unchanged; toggle on + Push now → `run` → `ok`. Then (optional, only if the user wants the full nr-kill rehearsal again) `nr-kill 120 --yes` → `run` → exit 4; recover per RUNBOOK 3.2.
   - **vzdump proof for CT 122**: `vzdump 122 --mode snapshot --storage backup-store --compress zstd`, then the RUNBOOK 1.9 proof with `<CTID>`=122, the control entry `usr/local/sbin/vault-restic-backup` instead of the service binary, and `srv/replica-ro/` instead of `srv/replica/`; additionally `zstd -dc "$A" | tar -t | grep -c 'etc/vault-backup/env'` is expected to be **1** (the env file is on the rootfs, same accepted exposure as CT 120's Google secret; note it) and the note-word grep is 0. Delete the archive. Confirm 122 is not in the nightly job.
   - **Isolation**: `diff /root/pct120.before <(pct config 120)` empty; `pct exec 120 -- ls /srv/replica-ro` fails (no such path); `pct exec 122 -- ls /srv/replica-ro/../state` fails; `pct exec 122 -- nft list ruleset | grep -c 'dport 22'` is 0; `grep -c notetaker-vaultbackup /usr/local/sbin/pve-offsite-backup.sh` is 0 and the existing `etc/notetaker-replica` exclude is still present (no new secret path to exclude: `/etc/vault-backup/env` lives inside CT 122, not on the host).
   - **Host reboot** (maintenance window the user picks; skip if any guest cannot be down): after `reboot`, `notetaker-replica-unlock status` unlocked, `pct status 120` and `122` running, `pct exec 122 -- findmnt -no OPTIONS /srv/replica-ro` contains `ro`, `systemctl list-timers vault-backup.timer` inside the CT shows the next 04:10.
9. **After two clean nightly runs** (`journalctl -u vault-backup -n 5` on two mornings, no check-failed mail): orchestrator doc pass, one commit: `scripts/backup/README.md` gets a top banner "LEGACY (Mac-side, repo path `vault`): superseded by `deploy/vault-backup/README.md` on <date>; its snapshots stay in B2; retire by user decision" and nothing else changes there; `deploy/remote-vault/RUNBOOK.md` gets a "Backup consumer" note (CT 122 mounts the inbox read-only; the fail-closed drill 3.3 now stops 122 too; `nr-kill` does not reach B2); `CLAUDE.md` one bullet under "Remote vault"; `specs/remote-vault/00-security-design.md` §9 dated note; `deploy/remote-vault/site/privacy.html` wording (§7 item 6); PROGRESS rows.

## 7. Threat notes

1. **Coverage gap (the first thing to know).** Locked notes, `_index.md`, hidden and non-`.md` files, oversize files, excluded folders and `remote: false` notes are **not in this backup** (§1). A loss of iCloud and the Mac loses them unless Time Machine has them. This is the price of backing up only the filtered copy; it is deliberate and must stay written in the README, this spec and the PROGRESS row.
2. **Compromised Mac.** It can push junk or an empty image into the inbox through CT 120's gate. The guards refuse an empty, tiny, disabled, half-pushed or digest-broken image (§5); junk that passes (a valid manifest over bad content) is snapshotted, and restic history plus "Keep all versions" is the recovery. The Mac holds **no** B2 or restic credential for the new repo and no ssh key to CT 122 (there is no sshd).
3. **Compromised CT 122.** Holds the filtered replica (read-only, same exposure class as CT 120 but with no public surface and no tokens), the daily B2 key and the restic password: an attacker can read every snapshot in `vault-replica/` and add junk, but cannot delete or prune (no `deleteFiles`; objects are hidden, not removed, under "Keep all versions"), cannot see the legacy repo (key prefix), cannot reach the Mac, the host, CT 120 or any RFC1918 address (nftables; the PVE firewall file mirrors inbound DROP), and cannot write to the replica (`ro=1`). Rotate both secrets from the B2 console and the password manager if it is suspected.
4. **Compromised CT 120.** Unchanged: it gains nothing from this work (no new mount, no credential, no route to CT 122).
5. **Host root / archives.** Host root sees the plaintext replica while the volume is mounted (accepted in design 00 §6). vzdump of 122 holds the rootfs including `/etc/vault-backup/env` (so a manual archive contains the daily key and restic password: same accepted class as CT 120's Google secret; 122 is not in the nightly job and `mp0` has `backup=0`, proven in §6 step 8). The offsite tar is unchanged (no new host-side secret). The restic cache on CT 122's rootfs holds only encrypted repository files.
6. **Kill switch versus backups (new, must be documented).** `nr-kill` and the Mac toggle wipe the live replica and index, but **snapshots taken before the kill remain in B2, encrypted with the restic password, until the monthly `forget --prune` with the admin key removes them by the retention rule (14 daily / 8 weekly / 12 monthly)**. A kill therefore stops serving and discards tokens, but does not erase the owner's own off-site backups; that is intended (a backup that a kill switch erases is not a backup). Proposed wording, the smallest honest change: in `privacy.html`, after "deletes every token, the search index and the copy of the data", add: "Encrypted backups of that copy, kept for the owner's own disaster recovery in storage the owner controls, are not deleted by the kill switch; they contain no tokens, no audit entries and no Google account data." and in the storage paragraph change "live on an encrypted volume" to "live on an encrypted volume; the notes copy is also backed up, encrypted, to off-site storage controlled by the owner". **Flag: the privacy policy does need this update** because its kill-switch sentence is currently a complete statement of what is deleted; the RUNBOOK 3.2 gets the same sentence. The Google branding verification does not depend on this text.
7. **Append-only semantics.** As in the legacy README: `restic backup` takes a shared lock and the B2 backend releases it by hiding the object; a stale lock needs the monthly `unlock` with the admin key; never "test" the daily key with `forget`.
8. **Logs.** restic error output can contain note paths (titles); it goes only to `/var/log/vault-backup/backup.log` (root 0600, CT 122 rootfs) and never to stdout, the journal, `last-run`, `last-failure` or mail.
9. **Staleness.** A replica older than 7 days produces `warn` and a snapshot; the host check turns `warn` into a mail every morning until the Mac pushes again. There is no mechanism that makes the snapshot fresher than the last push.

## 8. Verification

Builder (before handing back): §4.9 harness all `PASS` on the Mac; `shellcheck` and `bash -n` clean; README cross-check (§4.1 acceptance); `git status` shows only new files under `deploy/vault-backup/` and `specs/vault-backup/`.

Orchestrator (§6): mount proof (step 2), fail-closed drill (3), isolation and firewall checks (4, 8), manifest port proof against the real replica (5), cutover run + dedup + `restore-test PASS` (6), alert path proven by an induced failure (7), kill-switch and vzdump drills (8), host reboot when a window exists, two clean nightly runs before the doc pass (9). Every drill: PROGRESS row with observed output.

## 9. Non-goals

No Swift change (`ExportPolicy`, `ReplicaExporter`, `RemoteServer` untouched); no change to CT 120, its config, gate, units, nftables or the replica volume; no new LUKS volume or key; no Mac-side script, LaunchAgent, ssh key or Keychain change (the legacy job and its repo path `vault` keep running or not by the user's later decision); no sshd or Tailscale on CT 122; no B2 admin key anywhere on disk; no automatic `forget`/`prune`; no backup of `calendar-remote.json` or of CT 120's `state/`; no change to the nightly vzdump job or the offsite script.

## 10. Rules for the builder

- Read nothing under `~/.ssh`, `~/.claude.json`, any `.env`, `/etc/notetaker-remote/env`, `/etc/vault-backup/env`, the Keychain, or the password manager; never run anything against hildanet (192.168.5.100), CT 120 or B2. Local testing uses a local restic repository and a generated fixture only.
- Pre-existing uncommitted files that must **not** be touched, staged or reverted: `PROGRESS.md` (modified), `Packages/ConversionKit/Sources/ConversionKit/PythonEngineConverter.swift` (modified), `Packages/EditorKit/Package.resolved` (modified), `Notetaker 5.xcodeproj/` (untracked), `deploy/remote-vault/site/` (untracked), `scripts/backup/` (untracked: `vault-backup.sh`, `README.md`, `com.rchaight.notetaker-backup.plist.example` are the legacy Mac job and stay byte-identical).
- Create only files listed in §4; do not commit (the orchestrator commits). Build products and scratch dirs stay outside the repo (`~/.cache/` or `$TMPDIR`).

## 11. Flagged ambiguities and the smallest proposed fix

1. **"OnFailure alert via the host notification endpoint."** The CT cannot use the host's `mail` path (no relay; outbound 25 is blocked on this network **[verified: memory]**) and PVE has no ad-hoc notification API usable from a guest. Proposed: the alert is raised **on the host** by a daily `pct exec 122 -- verify-last` check unit whose `OnFailure` reuses the offsite job's mail unit pattern (§4.8); inside the CT, `OnFailure` only records the journal tail for that check to mail. Consequence: a 04:10 failure is mailed at 06:30, not immediately.
2. **"Alert, not fail, if the replica is older than 7 days."** Implemented as `warn` (exit 0, snapshot made) that the host check reports as a failure every morning (§7 item 9). If a daily mail during a long Mac absence is unwanted, the smallest change is a `VAULT_BACKUP_STALE_DAYS` knob; not added.
3. **"Verify manifest filesDigest if cheaply possible."** It is cheap (text-only replica, ~2 000 files): the check hashes every file and recomputes the digest on every run, and also catches strays and half-pushed trees. If step 5 of §6 measures over 60 s on the CT, fall back to digest-over-manifest-entries without rehashing (keep size checks) rather than dropping the check.
4. **Service runs as root.** Needed to read 2750 directories owned by CT 120's `replica:notetaker` uids inside CT 122's user namespace; mitigated by `CapabilityBoundingSet=CAP_DAC_READ_SEARCH` and the read-only mount. Alternative (a `notetaker` group with CT 120's gid) depends on an id recorded nowhere; not chosen. **[unverified]** item to confirm in §6 step 2: root in CT 122 can in fact read the inbox (if not, both CTs' idmaps differ and the orchestrator stops and asks).
5. **`ro=1` on a bind-mounted `mp0` in PVE 9.2.5** is assumed to work; §6 step 2 proves it with `findmnt` and an `EROFS` touch before anything else happens, and `setup.sh` refuses to run without it.
6. **Privacy page wording** needs the §7 item 6 addition (flagged yes).
7. **Fail-closed drill now stops CT 120 too** (the unlock unit cannot close the volume while 120 holds it), so RUNBOOK 3.3's drill wording must mention 122; the doc pass in §6 step 9 covers it.

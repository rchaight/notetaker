# Server-side vault backup (restic to B2, CT 122)

Nightly, versioned, encrypted backup of the remote-vault **replica** from a
dedicated container, CT 122 `vault-backup`, to the existing B2 bucket under the
repository path `vault-replica`. Nothing depends on the Mac. Build contract:
`specs/vault-backup/00-server-side-backup.md`. Host and Proxmox steps are the
orchestrator's runbook (spec section 6), not this file.

## 1. What this backup does NOT cover (read first)

**This backup covers exactly what the replica holds and nothing more.** The
replica is the filtered copy the Mac pushes (`ReplicaExporter` under
`ExportPolicy`), which by design excludes:

- **locked notes** (`locked: true`, locked envelopes, unclosed frontmatter with a lock key);
- `_index.md` at any depth, hidden/dot files, `.icloud` placeholders and dataless files;
- every **non-`.md`** file (attachments, images, PDFs);
- files over the exporter's size cap, symlinks, hard-linked files, name collisions;
- every folder listed in Settings > Remote > **Excluded folders** (at least `private`), and notes with `remote: false`.

**Those files have no server-side backup after this change. Their only copies remain iCloud and Time Machine.**

The backup is also only as fresh as the last push: if the Mac is off for days,
the replica and therefore the snapshot are days old. That is surfaced as a
warning (`warn`), not a failure.

## 2. Architecture and fixed names

```
hildanet LUKS volume /mnt/notetaker-replica/srv/{inbox,state}
   inbox -> CT 122 mp0 ro=1  /srv/replica-ro/{vault/,manifest.json,calendar-remote.json|DISABLED}
CT 122: vault-backup.timer 04:10 -> vault-restic-backup run -> restic -> B2 bucket <BUCKET>, path vault-replica/
host:   notetaker-vaultbackup-check.timer 06:30 -> pct exec 122 -- vault-restic-backup verify-last -> mail root
```

CT 122 is unprivileged, has no Tailscale, no sshd and no inbound network, and
nftables (`inet vaultbackup`) allows out only DNS, NTP and TCP 443 to non-RFC1918
addresses (TCP 80 only inside a `vb-maint` window). It sees the inbox only,
never `state/` (tokens, index).

| Item | Value |
|---|---|
| CT id / hostname / IP | `122` / `vault-backup` / `<CT122_IP>` (static, same bridge and gateway as CT 120, `firewall=1`, `--nameserver 1.1.1.1`) |
| CT resources | unprivileged, `nesting=0`, no `dev0`, 2 cores, 2048 MB RAM, 512 MB swap, rootfs `local-lvm:8`, `onboot 1` |
| Mount | `mp0: /mnt/notetaker-replica/srv/inbox,mp=/srv/replica-ro,ro=1,backup=0` |
| Source dir in CT | `/srv/replica-ro` (override `VAULT_BACKUP_SOURCE` for tests only) |
| Backup set | `restic backup --host nr-replica --tag notetaker-replica --exclude /srv/replica-ro/calendar-remote.json /srv/replica-ro` |
| Repository | `RESTIC_REPOSITORY=b2:<BUCKET>:vault-replica` |
| Env file | `/etc/vault-backup/env`, root 0400: `RESTIC_REPOSITORY`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`, `RESTIC_PASSWORD`, `RESTIC_CACHE_DIR=/var/cache/vault-backup` |
| State dir | `/var/lib/vault-backup/` root 0700: `last-success`, `last-run`, `last-failure`, `accept-shrink`, `lock` |
| Log | `/var/log/vault-backup/backup.log` root 0600, trimmed to the last 2000 lines once over 1 MiB |
| Restore scratch | `/run/vault-backup/restore` (tmpfs, RAM only) |
| Timer | `vault-backup.timer`: `OnCalendar=*-*-* 04:10:00`, `Persistent=true`, `RandomizedDelaySec=0` |
| Host check | `notetaker-vaultbackup-check.timer` 06:30 daily; `OnFailure=notetaker-vaultbackup-check-failed.service` |
| B2 daily key | capabilities exactly `listBuckets listFiles readFiles writeFiles`, bucket-restricted, name prefix `vault-replica/` |

Files: `ct/setup.sh` (run `bash setup.sh`, then `bash setup.sh --yes`, inside the
CT), `ct/vault-restic-backup` (installed to `/usr/local/sbin/`),
`ct/manifest-check.py` (`/usr/local/lib/vault-backup/`), `ct/vb-maint`,
`ct/nftables.conf`, `ct/vault-backup.service`, `ct/vault-backup.timer`,
`ct/vault-backup-failed.service`, `ct/env.example`, and on the host
`host/pve-firewall.122.fw.example`, `host/notetaker-vaultbackup-check.service`,
`host/notetaker-vaultbackup-check.timer`,
`host/notetaker-vaultbackup-check-failed.service`. Local tests: `test/run-local.sh`.

Subcommands of `vault-restic-backup`: `run` (default), `check`, `snapshots`,
`restore-test`, `status`, `verify-last`, `accept-shrink`.

## 3. What each guard refuses

`run` checks in this order; the first failing guard wins and no snapshot is made, except `concurrent_push`, which is detected after the snapshot.

| Guard | `last-run` | Exit |
|---|---|---|
| another run holds `/var/lib/vault-backup/lock` | unchanged | 5 |
| env file missing, not mode 0400, or still has `<PLACEHOLDER>` values | `fail ... 1` | 1 |
| `/srv/replica-ro` is not a read-only mount point | `fail ... 1 source_not_ro` | 1 |
| `DISABLED` marker present (Mac toggle off, `nr-kill`), manifest missing or invalid, count mismatch, missing/size/SHA-256 mismatch, stray `.md`, non-regular file, bad path, digest mismatch | `skip ... 4 <reason>` | 4 |
| fewer than 100 notes (`VAULT_MIN_NOTES`) | `skip ... 4 below_floor` | 4 |
| more than 20 % fewer notes than the last success (`count * 5 < last * 4`, last >= 100) | `skip ... 4 shrink` | 4 |
| manifest `generatedAt` older than 7 days | `warn ... 0 stale`; snapshot is still made | 0 |
| manifest or tree changed while restic ran (post-check differs) | `warn ... 0 concurrent_push`; snapshot exists, `last-success` kept | 0 |

`last-run` is one line, `<ok|warn|skip|fail> <ISO-8601 UTC> <code> <message>`,
with a fixed message and numbers only (it is mailed; it never holds a note path).
`last-success` is `count=<N> generated_at=<ISO> snapshot=<short id> at=<ISO>`,
written only after restic exit 0. Reason tokens: `disabled_marker`,
`manifest_missing`, `manifest_invalid`, `manifest_disabled`, `count_mismatch`,
`entry_missing`, `entry_size`, `entry_sha256`, `stray_file`, `not_regular`,
`bad_path`, `digest_mismatch`, plus `manifest_check_error` (the wrapper's fallback when the checker fails unexpectedly). An unreadable file or directory in the checker maps to `not_regular`.

Exit 3 means restic made a snapshot but could not read some files: a read-only
bind should never do that, so investigate. Exit 4 and 3 fail the service on
purpose so the host check sees them.

**`accept-shrink`.** When the replica legitimately shrank by more than 20 %
(you deleted a big folder), run `vault-restic-backup accept-shrink` and then
`vault-restic-backup run`. The next run may go below the floor once; it removes
the `accept-shrink` file whether or not it was needed.

`vault-restic-backup verify-last` (no restic call, no network): exit 0 if
`last-run` is `ok` and under 26 h old; exit 2 if it is `warn` (stale replica);
otherwise exit 1. It prints the `last-run` line and the first 20 lines of
`last-failure`. A 04:10 failure is mailed at 06:30, not immediately, because the
CT has no mail relay.

**Troubleshooting.** If the first run exits 3 with "operation not permitted" in
the log, the cause is restic's `O_NOATIME` open needing `CAP_FOWNER`. Add
`CAP_FOWNER` to `CapabilityBoundingSet` in `vault-backup.service` only if the CT
proves it. A `warn ... 0 concurrent_push` means a push landed while restic was
reading; `last-success` was not updated, and the next run decides.

## 4. Kill switch versus backups

`nr-kill` and the Mac toggle wipe the live replica and index, but **snapshots taken before the kill remain in B2, encrypted with the restic password, until the monthly `forget --prune` with the admin key removes them by the retention rule (14 daily / 8 weekly / 12 monthly)**. A kill therefore stops serving and discards tokens, but does not erase the owner's own off-site backups; that is intended (a backup that a kill switch erases is not a backup).

With the inbox in either kill image (`DISABLED` plus a `disabled: true`
manifest, or `DISABLED` alone), the `disabled_marker` guard refuses first, so no
snapshot of an empty replica is ever created and `last-success` keeps the
previous count.

## 5. B2 setup for the new key and repository

1. Use the existing private bucket (SSE-B2, "Keep all versions"; see the legacy
   README for why: with an append-only key restic removes objects by hiding them,
   and a "keep only the last version" rule would hard-delete the safety net).
2. B2 console: create a new application key for that bucket with capabilities
   exactly `listBuckets listFiles readFiles writeFiles` and **name prefix
   `vault-replica/`**. No `deleteFiles`. The admin key (all capabilities) stays in
   the password manager and on no disk.
3. Generate the repository password and put it in the password manager too:
   `openssl rand -base64 33`
4. Put the five values into `/etc/vault-backup/env` by hand (`pct enter 122`,
   `unset HISTFILE`, `nano /etc/vault-backup/env`). `ls -l` must show
   `-r-------- root root`. The admin key never goes in this file. Keep the file to
   the five `KEY=value` lines: lines without `=` make systemd log the line text to the journal.
5. Initialise the repository with the **admin** key typed into a `read -rs` shell:
   ```
   pct enter 122
   unset HISTFILE
   read -rs -p "B2 key id: " B2_ACCOUNT_ID; echo; read -rs -p "B2 key: " B2_ACCOUNT_KEY; echo; read -rs -p "restic password: " RESTIC_PASSWORD; echo
   export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
   restic -r b2:<BUCKET>:vault-replica init
   unset B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
   exit
   ```
6. First run: `vault-restic-backup run`, then `vault-restic-backup snapshots`
   (one snapshot, host `nr-replica`, tag `notetaker-replica`). Do not "prove" the
   daily key with `restic forget`: a key that cannot delete makes restic's B2
   backend *hide* objects, so `forget` appears to succeed and hides your snapshot.

## 6. Monthly maintenance (admin key, by hand)

```
pct enter 122
unset HISTFILE
read -rs -p "B2 key id: " B2_ACCOUNT_ID; echo; read -rs -p "B2 key: " B2_ACCOUNT_KEY; echo; read -rs -p "restic password: " RESTIC_PASSWORD; echo
export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
export RESTIC_CACHE_DIR=/var/cache/vault-backup
restic -r b2:<BUCKET>:vault-replica unlock
restic -r b2:<BUCKET>:vault-replica forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
restic -r b2:<BUCKET>:vault-replica check --read-data-subset=5%
unset B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
```

`unlock` first because `restic backup` takes a shared lock that the append-only
key releases by hiding the lock object; a failed release leaves a stale lock.
With the admin key, prune hard-deletes. Do not run `forget` with the daily key.
Keep "Keep all versions" on the bucket: it is what lets you restore a previous
good version if the daily key is ever misused. Also run
`vault-restic-backup check` and `vault-restic-backup restore-test` occasionally.

## 7. Restore

Drill (after setup, then quarterly): `vault-restic-backup restore-test`. It
restores the latest snapshot into `/run/vault-backup/restore` (tmpfs, RAM only;
it refuses with "raise CT 122 memory" if there is not room), runs
`diff -rq` against the replica, prints one `PASS`/`FAIL` line and removes the
scratch. A push since the last run can cause a spurious `FAIL`; run `run` first.

Real recovery, with the daily credentials in the environment (as in section 5
step 5, daily key instead of admin):
```
restic -r b2:<BUCKET>:vault-replica restore latest --host nr-replica --tag notetaker-replica --target <dir> --include <path>
```
restic recreates `/srv/replica-ro/...` under the target. Only filtered notes are
in it (section 1).

## 8. The legacy Mac job

`scripts/backup/` (the Mac LaunchAgent, its Keychain items and the repository
path `vault`) is untouched by this work and keeps its existing snapshots. It is
the only job that covered locked notes, attachments and excluded folders.
Retiring it is a separate decision for the user.

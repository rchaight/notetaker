# Vault backup (restic to Backblaze B2)

Daily, versioned, encrypted backup of the iCloud vault. The Mac holds only an
append-only B2 key: it can add data but cannot delete or prune. Pruning needs
the admin key, which lives only in the password manager.

## One-time setup

1. B2: create a **private** bucket, Server-Side Encryption (SSE-B2) on, and keep the
   default lifecycle setting **"Keep all versions"** (no lifecycle rules). With the
   append-only key, restic removes objects by *hiding* them, and a "keep only the
   last version" rule would hard-delete those hidden versions after a day, which
   would erase the safety net if the Mac were compromised.
2. B2: create two application keys, both restricted to that bucket:
   - **daily**: listBuckets, listFiles, readFiles, writeFiles. No deleteFiles.
   - **admin**: all capabilities. Store only in the password manager, never on the Mac.
3. `brew install restic`
4. Generate the repository password and save it in BOTH the Keychain (step 6) and
   the password manager. Losing it makes every backup unreadable.
   `openssl rand -base64 33`
5. Initialize the repository with the **admin** key (type values at the prompts):
   ```
   read -rs B2_ACCOUNT_ID; read -rs B2_ACCOUNT_KEY; read -rs RESTIC_PASSWORD
   export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
   restic -r b2:BUCKET:vault init
   unset B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
   ```
6. Add the four Keychain items (each command prompts for the value; use the
   **daily** key here):
   ```
   security add-generic-password -U -s notetaker-backup-b2-key-id -a "$USER" -w
   security add-generic-password -U -s notetaker-backup-b2-key -a "$USER" -w
   security add-generic-password -U -s notetaker-backup-restic-password -a "$USER" -w
   security add-generic-password -U -s notetaker-backup-b2-bucket -a "$USER" -w
   ```
7. First run, then list the snapshot:
   ```
   scripts/backup/vault-backup.sh run
   scripts/backup/vault-backup.sh snapshots
   ```
   In the B2 console confirm the **daily** key has exactly listBuckets, listFiles,
   readFiles and writeFiles and is restricted to the bucket. Do not "prove" it by
   running `restic forget` with it: with a key that cannot delete, restic's B2
   backend falls back to *hiding* objects, so `forget` would appear to succeed and
   hide your snapshot. That fallback is why step 1 says "Keep all versions".

## The daily job

`vault-backup.sh run` backs up the vault (default subcommand) with
`restic backup`, which always takes a shared repository lock; with the append-only
key the lock is released by hiding the lock object. If a release ever fails, a
stale lock can remain, which is why the monthly maintenance below starts with
`restic unlock`. It refuses to run (and notifies) if the vault
has fewer than 100 files, so an unmounted iCloud never produces an empty
snapshot. Log: `~/Library/Logs/notetaker-backup.log` (trimmed to 2000 lines past
about 1 MB). It holds no secrets, but restic error text can mention the bucket.

Other subcommands: `snapshots`, `check` (5% data sample), `restore-test`.

Install as a LaunchAgent (03:30 daily):
```
sed "s#/Users/YOU#$HOME#g" scripts/backup/com.rchaight.notetaker-backup.plist.example \
  > ~/Library/LaunchAgents/com.rchaight.notetaker-backup.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.rchaight.notetaker-backup.plist
launchctl print gui/$(id -u)/com.rchaight.notetaker-backup
```
Run it now with `launchctl kickstart gui/$(id -u)/com.rchaight.notetaker-backup`.
Uninstall:
```
launchctl bootout gui/$(id -u)/com.rchaight.notetaker-backup
rm ~/Library/LaunchAgents/com.rchaight.notetaker-backup.plist
```
The agent reads the Keychain, so it runs only while you are logged in. If the
Keychain prompts, choose "Always Allow" for `security` once (any process running as
you can then read those four items without a prompt: that is the accepted
single-user trade-off). A run missed while the Mac was asleep fires on wake; one
missed while it was shut down is not made up. If the login keychain locks on sleep,
the wake-time run can fail with a Keychain error.

**First run under launchd.** Terminal and launchd get different macOS privacy
grants. After installing, run `launchctl kickstart gui/$(id -u)/com.rchaight.notetaker-backup`
and read `~/Library/Logs/notetaker-backup.log`: you should see "Vault OK: N files".
If you see "Vault has only 0 files" or "Operation not permitted", give Full Disk
Access to `/bin/bash` and the restic binary (System Settings > Privacy & Security).
`launchctl print gui/$(id -u)/com.rchaight.notetaker-backup` shows the last exit
code. The agent's plist points into this git checkout, so moving the repo breaks it.

## Monthly maintenance (admin key, by hand)

Export the admin credentials as in setup step 5, then:
```
restic -r b2:BUCKET:vault unlock
restic -r b2:BUCKET:vault forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
restic -r b2:BUCKET:vault check --read-data-subset=5%
```
Then unset the variables. With the admin key, prune hard-deletes. If you ever
suspect the daily key was misused, `check` reports damage; in the B2 console
(or with the admin key) delete the junk file versions or the hide markers to
bring back the previous good version, which "Keep all versions" preserves. Also run `vault-backup.sh check` and `restore-test` occasionally.

## Restore drill (do this after setup, then quarterly)

```
scripts/backup/vault-backup.sh restore-test
```
It restores the latest snapshot to a temp directory, runs `diff -rq` against the
vault with the same excludes, prints one PASS/FAIL line and deletes the temp dir.
Edits made after the last backup can cause a spurious FAIL; run `run` first.
To recover real files: `restic -r b2:BUCKET:vault restore latest --target ~/restore --include PATH`
with the daily credentials exported (restic recreates the absolute source path
under the target).

## Deliberately not backed up

- `_index.md` (app-generated, rebuilt by Notetaker), `.DS_Store`, `*.icloud`
  placeholders, `.Trash`.
- The GRDB index and other derived state: rebuildable from the vault files.
- The B2 admin key and the restic password never live in the repo; the password is
  also in the password manager.
- Evicted (dataless) vault files are downloaded by iCloud when read; that is expected.

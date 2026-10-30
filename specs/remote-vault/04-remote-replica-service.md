# Spec 04 — App glue: `RemoteReplicaService`, push, calendar-remote.json, Settings › Remote, Mac-side kill switch

Design: `00-security-design.md` §3 (Mac box), §4.3 + §9 (calendar scope),
§4.6 (replication, triggers, kill switch), §1 (SSH key), §6 (scope
switches), §7 T4 + T5 merged (see `01-overview.md`: no schema 2).
Depends on spec 03 and on the calendar work being committed. Builder:
sonnet. Stage: builds and exports with no infrastructure; the push is
exercised at stage 1 against the CT from spec 08.

## Scope

macOS-only app service that (a) keeps the export staging image fresh via
`ReplicaExporter`, (b) writes the remote calendar snapshot into it, (c)
pushes it to the container over ssh/rsync on a Tailscale address with a
dedicated app-generated key and a pinned host key, (d) exposes everything
in a new Settings › Remote tab, and (e) implements the Mac-side kill
switch (toggle off = push the disabled image). iOS: compiled out entirely.

## Design

### Settings keys (all `UserDefaults.standard`; none secret)

| key | type | default | meaning |
|---|---|---|---|
| `remoteAccessEnabled` | Bool | false | master switch + kill switch |
| `remoteHost` | String | "" | Tailscale IPv4 (100.64.0.0/10), Tailscale IPv6 (fd7a:115c:a1e0::/48) or `*.ts.net` name — anything else is rejected with a caption ("Use the container's Tailscale address, never a LAN address" — design §4.6) |
| `remoteUser` | String | `replica` | ssh login |
| `remoteRsyncPath` | String | `/usr/bin/rsync` | openrsync on this Mac (verified); user may point at a Homebrew rsync if stage 1 finds an incompatibility |
| `remoteIncludeCalendar` | Bool | true | write `calendar-remote.json` (needs calendar access; honours Settings › Calendar exclusions by construction) |
| `remoteExcludedFolders` | String | "" | newline-separated vault-relative folders → `ExportPolicy(excludedFolders:)` |
| `remoteHostKeyTrusted` | Bool | false | set by the "Trust this host" button after the fingerprint is shown |

Files under `~/Library/Application Support/Notetaker/RemoteExport/`
(created 0700): `staging/` (spec 03), `id_ed25519` (0600) + `.pub`,
`known_hosts`, `last-push.json` (status for Settings). Key material is a
file, not a Keychain item, because `/usr/bin/ssh` needs a path (design §4.6).

### `App/Services/RemoteReplicaService.swift` (`#if os(macOS)`, `@MainActor final class`, owned by `AppShell` as `@State`, started from the existing macOS `.task` next to `calendarSnapshotPublisher.start()`)

- `start()`: clean `staging.tmp-*`/`staging.old-*` leftovers; ensure the
  key pair exists (`/usr/bin/ssh-keygen -t ed25519 -N "" -C notetaker-remote -f <path>`
  via `Process`, then `chmod 0600`); subscribe to triggers; if enabled, run
  an export + push.
- Triggers (each coalesces into one pending job; a job = export, then push
  if a host is configured and trusted):
  - `VaultIndexService.didSettleNotification` — **new** `static let
    didSettleNotification = Notification.Name("com.rchaight.notetaker.vaultIndexDidSettle")`
    posted by `VaultIndexService` at the point it calls
    `publishWidgetSnapshot()` after an indexing pass (one line); 30 s
    debounce (design §4.6).
  - `.EKEventStoreChanged` when `remoteIncludeCalendar` (2 s debounce).
  - 5-minute repeating timer while the app runs (§9).
  - `UserDefaults.didChangeNotification` when any `remote*` key changed
    (mirror `CalendarSnapshotPublisher.configKey()`).
  - "Push now" button.
- Jobs are serialised (one `Task` at a time; a trigger during a job sets a
  `rerun` flag). After a failed push, the next attempt waits ≥ 60 s.
- Export: `ReplicaExporter(root: indexService.vaultRootURL, staging:,
  policy: ExportPolicy(excludedFolders:))`, `calendarSnapshot:` =
  `SnapshotCodec.encode(CalendarService.snapshot(daysBack: 7, daysAhead: 60))`
  when included and `CalendarService.accessState() == .granted`, else nil.
  `appVersion:` = `CFBundleShortVersionString`. Errors (incl.
  `selfCheckFailed`) go to `os.Logger` + the status line; never crash.
- Push (only when `remoteHost` valid, `remoteHostKeyTrusted`, key exists):
  two `Process` runs, each with a 120 s watchdog, stdout/stderr captured
  to the status (last 2 KB) and the log:
  ```
  <rsync> -rlt --delete --timeout=60 --exclude=manifest.json -e "<ssh>" <staging>/ <user>@<host>:/
  <rsync> -lt --timeout=60 -e "<ssh>" <staging>/manifest.json <user>@<host>:/manifest.json
  <ssh> = /usr/bin/ssh -i <key> -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<known_hosts> -o BatchMode=yes -o ConnectTimeout=10 -o PasswordAuthentication=no
  ```
  Manifest last so its mtime marks a complete push (design §4.1); rsync
  transfers in sorted path order, so one run would send `manifest.json`
  before `vault/` — hence two runs. `--exclude=manifest.json` without
  `--delete-excluded` leaves the remote manifest alone during run 1.
  Flags are limited to what openrsync and `rrsync -wo` both accept
  (`-r -l -t --delete --timeout --exclude -e`); no `-z`, `-a`, `--chmod`,
  `--delete-delay`. `:/` is the rrsync-restricted root (the inbox).
  Environment for the child: `PATH=/usr/bin:/bin`, nothing inherited.
- Host-key pinning (TOFU shown to the user): "Fetch host key" runs
  `/usr/bin/ssh-keyscan -t ed25519 -T 5 <host>`; the result's SHA256
  fingerprint (`ssh-keygen -lf` on a temp file) is displayed; "Trust this
  host" writes the line to `known_hosts` and sets `remoteHostKeyTrusted`.
  Changing `remoteHost` clears trust and truncates `known_hosts`.
- `last-push.json`: `{at, ok, bytesSent?, notes, lockedExcluded, indexExcluded, otherExcluded, notDownloaded, calendarIncluded, message}`.
- **Kill switch** — `remoteAccessEnabled` flips to false: cancel triggers,
  `ReplicaExporter.writeDisabled(staging:)`, push (both runs; run 1's
  `--delete` empties the inbox), status "Remote access off; replica wiped
  at <time>" or, on failure, "Remote access off, but the wipe did not
  reach the container (<reason>). Run the container kill switch (`pct exec
  <id> -- notetaker-remote kill`) or retry." + a "Retry wipe" button.
  While off, no trigger does anything; "Push now" is disabled.
- Flip to true: export + push immediately.

### Settings › new tab `Tab("Remote", systemImage: "antenna.radiowaves.left.and.right")` (macOS only, after Calendar)

Sections (all captions `.font(.caption).foregroundStyle(.secondary)`):

1. **Remote access** — the toggle, then the plain statement of what leaves
   the Mac when on: "Every unlocked note (full text) and, if enabled below,
   your calendar — title, time, location, status, organizer and attendee
   names — are copied to your own container over Tailscale for the
   read-only MCP server you connect to claude.ai. Never copied: locked
   notes, `_index.md` files, hidden files, non-markdown files, folders you
   exclude below, notes with `remote: false` in their frontmatter, event
   notes, links, or email addresses. Turning this off wipes the copy."
2. **Container** — `remoteHost` field (validation caption), `remoteUser`,
   `remoteRsyncPath`, host-key row: fingerprint or "not fetched", buttons
   Fetch / Trust.
3. **This Mac's key** — the public key (monospaced, selectable) + Copy
   button + caption "Paste this into the container's authorized_keys as
   described in the runbook (restricted to upload-only)." + "Regenerate
   key" (confirm dialog; clears nothing remote — the runbook step repeats).
4. **Scope** — `remoteIncludeCalendar` (disabled with caption when
   calendar access is not granted), `remoteExcludedFolders` `TextEditor`
   (monospaced, one folder per line, caption with an example).
5. **Status** — `LabeledContent` rows from `last-push.json` and the current
   manifest: last export (time, notes, locked excluded, index excluded,
   other excluded, not downloaded), last push (time, ok/failed, message),
   buttons "Push now", "Verify export" (runs `ReplicaExporter.verify` and
   shows "0 violations in N files" or lists them), "Reveal staging folder".

Also: Settings › Security "Locked notes" caption gains one sentence:
"Locked notes are never included in the remote copy (Settings › Remote)."

### `AppShell.swift`

`@State private var remoteReplicaService = RemoteReplicaService()` beside
the calendar publisher; `.task { remoteReplicaService.start(indexService:) }`
inside the existing `#if os(macOS)` block.

## Acceptance criteria (manual — the app target has no unit tests; package behaviour is covered by 02/03)

Counts only; never print note contents.

1. Fresh launch, Remote tab off: `RemoteExport/` exists with the key pair
   (0600/0644), no `staging/`. iOS build green (grep: every new symbol is
   inside `#if os(macOS)`).
2. Toggle on with an empty host: within ~35 s `staging/` exists;
   `find staging -name _index.md | wc -l` → 0;
   `grep -rl "^locked: true" staging/vault | wc -l` → 0;
   `jq .lockedExcludedCount staging/manifest.json` equals
   `grep -rl "^locked: true" "<vault>" --include='*.md' | wc -l` (the
   user's real locked count — builder runs this grep with `-l | wc -l`
   only); `jq .noteCount` equals `find staging/vault -name '*.md' | wc -l`;
   Status shows the same numbers; "Verify export" → 0 violations.
3. Edit a note in the app → Status "last export" advances within ~35 s
   (settle notification + debounce). Wait 5 min → advances again (timer).
4. `remoteIncludeCalendar` on with access granted: `staging/calendar-remote.json`
   exists, `jq .schemaVersion` = 1, `grep -c '"notes"\|"url"\|"email"'` = 0,
   range spans ~67 days (`jq .rangeStart,.rangeEnd`); off → file gone
   after the next export.
5. `remoteExcludedFolders` = an existing folder → its notes disappear from
   staging on the next export; `otherExcludedCount` rises by that many.
6. Host set to `192.168.5.50` → rejected caption, no push; set to a
   `100.x.y.z` or `*.ts.net` value with no CT yet → "Fetch host key" fails
   with the ssh-keyscan message in Status; no push attempted while untrusted.
7. Toggle off: `staging/` contains exactly `DISABLED` and `manifest.json`
   (`jq .disabled` = true); Status explains the push could not run (no
   host) in plain words. Toggle on → full image again.
8. Stage 1 (after spec 08, user-run): with a real host, "Fetch host key"
   shows a fingerprint matching `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
   in the CT; "Trust" → "Push now" → Status ok; on the CT
   `ls /srv/replica/inbox` shows `vault/ calendar-remote.json manifest.json`
   and `manifest.json` is the newest file; toggle off → inbox holds exactly
   `DISABLED manifest.json`. `ssh -i <key> replica@<host> id` from the Mac
   → refused (rrsync rejects non-rsync commands).
9. `scripts/verify.sh 3 --install` green; launch OK; no new permission
   prompts (ssh/rsync are plain processes; the app is unsandboxed).

## Files expected to change

- new `App/Services/RemoteReplicaService.swift`
- `App/Services/VaultIndexService.swift` (one `static let` + one
  `NotificationCenter.default.post` line)
- `App/Shell/AppShell.swift` (own + start)
- `App/Shell/SettingsView.swift` (new tab; one caption in Security)
- `PROGRESS.md` (one row)

Must not change: `CalendarService.swift`, `CalendarSnapshotPublisher.swift`
(the local MCP snapshot stays independent), `VaultKit`/`MarkdownKit`
(report gaps), `project.yml` (no new package links: VaultKit, CalendarKit,
MarkdownKit are already linked), entitlements/Info.plist (no new usage
strings needed), `~/.ssh/*` (the app uses its own key and known_hosts
files only — `UserKnownHostsFile` and `IdentitiesOnly` guarantee it).

## Non-goals

- Pull mode, bidirectional sync, or any write path from the container.
- Keychain storage of the ssh key or a passphrase-protected key (design §6
  accepts an unprotected key for unattended pushes).
- Using the LAN address, mDNS, or a non-Tailscale host.
- A menu-bar indicator, notifications on push failure (Status line only).
- iOS.

## Verification commands

```bash
cd ~/Developer/Notetaker && xcodegen generate && swiftformat --lint .
DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -project Notetaker.xcodeproj -scheme Notetaker \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ~/.cache/notetaker-build/DerivedData build CODE_SIGNING_ALLOWED=NO
scripts/verify.sh 1 --install     # loop; then the manual criteria above
ls -la ~/Library/Application\ Support/Notetaker/RemoteExport/
jq '{noteCount,lockedExcludedCount,indexExcludedCount,otherExcludedCount,notDownloadedCount,calendarIncluded,disabled}' \
  ~/Library/Application\ Support/Notetaker/RemoteExport/staging/manifest.json
scripts/verify.sh 3 --install     # before commit; exit code captured directly
```

## Builder notes

**sonnet** — follows `CalendarSnapshotPublisher` (lifecycle), the
`PythonEngineConverter`/docling `Process` usage in ConversionKit (child
process pattern with timeouts) and the Settings pane conventions. Known
trap: the macOS beta toolbar bridge — Settings is a `TabView`/`Form`, fine;
do not add `.toolbar`/`.searchable`. `notetaker-swift-reviewer` before
merge (actor isolation around `Process` termination handlers).

Open question for stage 1 (not blocking the build): openrsync's
`--server` argument line vs. `rrsync`'s parser is unverified. If the first
real push fails with an rrsync "option not allowed" error, the user installs
`brew install rsync` and points `remoteRsyncPath` at `/opt/homebrew/bin/rsync`;
record the outcome in PROGRESS.

# Spec 03 — `VaultKit.ReplicaExporter` + `manifest.json`

Design: `00-security-design.md` §3 (staging dir), §4.1 (manifest, pushed
last), §4.6 (filtering through the enumeration choke point, atomic swap,
Mac-side kill switch = empty push + `DISABLED`), §5 gate 1 + test 2, §7 T3.
Depends on spec 02. Builder: sonnet. Stage: pure — temp directories only.

## Scope

Build the complete remote replica image on the Mac into a non-iCloud
staging directory: every vault note that passes `ExportPolicy`, an optional
`calendar-remote.json`, and `manifest.json`, assembled in a temp sibling
and swapped in atomically; plus a self-check that refuses to swap in a tree
containing anything the policy would exclude; plus the "disabled" image
the kill switch pushes. No network, no ssh, no rsync (spec 04).

## Design

### Types (`Packages/VaultKit/Sources/VaultKit/ReplicaExporter.swift`)

```swift
public struct ReplicaManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public struct Entry: Codable, Equatable, Sendable { public let path: String; public let sha256: String; public let bytes: Int }
    public let schemaVersion: Int
    public let generatedAt: Date            // ISO 8601 in JSON
    public let policyVersion: Int           // ExportPolicy.version
    public let disabled: Bool
    public let noteCount: Int
    public let lockedExcludedCount: Int     // .locked + .lockedEnvelope + .unclosedFrontmatterWithLockKey
    public let indexExcludedCount: Int      // .indexFile
    public let otherExcludedCount: Int      // every other reason
    public let notDownloadedCount: Int      // iCloud placeholders skipped
    public let calendarIncluded: Bool
    public let files: [Entry]               // sorted by path; vault-relative, no "vault/" prefix
    public let filesDigest: String          // sha256 of "\(path)\n\(sha256)\n" concatenated in order
    public let appVersion: String?
}

public struct ReplicaExporter: Sendable {
    public struct Result: Sendable, Equatable { public let manifest: ReplicaManifest; public let stagingURL: URL }
    public enum ExporterError: Error, Equatable {
        case selfCheckFailed(path: String, reason: ExportExclusionReason)
        case stagingUnavailable(String)
    }
    public init(root: URL, staging: URL, policy: ExportPolicy, fileStore: VaultFileStore = VaultFileStore())
    /// Full rebuild. `calendarSnapshot` is already-encoded JSON from CalendarKit's codec (the app passes it; VaultKit does not import CalendarKit).
    public func export(calendarSnapshot: Data?, appVersion: String? = nil, now: Date = Date()) async throws -> Result
    /// The kill-switch image: staging contains only `DISABLED` (empty) and a manifest with disabled:true, files:[].
    public static func writeDisabled(staging: URL, now: Date = Date()) throws -> ReplicaManifest
    /// Walks `staging/vault` and re-applies the policy to every file; used by `export` before the swap and by Settings › "Verify export".
    public static func verify(staging: URL, policy: ExportPolicy) throws -> Verification
    public struct Violation: Sendable, Equatable { public let path: String; public let reason: ExportExclusionReason }
    public struct Verification: Sendable, Equatable { public let fileCount: Int; public let violations: [Violation] }
}
```

Layout of `staging/`:

```
staging/
  vault/<relativePath>.md     exported notes, tree preserved (+ CLAUDE.md at the root if present)
  calendar-remote.json        optional
  manifest.json               always last written
  DISABLED                    only in the disabled image (and then vault/ and calendar are absent)
```

### Enumeration and reading

- Enumerate with `VaultEnumerator.snapshot(of: root)` — the existing choke
  point that already drops `_index.md` and hidden files. The policy is
  still applied to every item (defense in depth; counters come from the
  policy's reasons, so `indexExcludedCount` is computed by calling
  `policy.decide(relativePath:)` on the raw enumeration **before** the
  enumerator's own filter would hide them — if `VaultEnumerator` has
  already removed them, add an internal `VaultEnumerator.snapshot(of:includingIndexFiles:)`
  overload or count via a second cheap `FileManager.enumerator` pass; the
  builder picks the smaller change and says which).
- Skip directories. Skip items whose `VaultItem.downloadState` is not
  downloaded/current (count `notDownloadedCount`); **never** call
  `startDownloading` — pulling the whole vault is not this feature's job
  and a placeholder's absence is reported, not fixed.
- Read through `fileStore.readString(at:)` (NSFileCoordinator, as all vault
  reads must). A coordinated read that throws for one file → that file is
  skipped and counted under `otherExcludedCount` with a log line; the
  export continues (iCloud may be mid-write).
- Decide with `policy.decide(relativePath:contents:)`; write exports into
  `staging.tmp-<uuid>/vault/<relativePath>` with plain `Data.write` (the
  staging dir is app-private, not iCloud, so coordination is not needed).
- **Preserve the source mtime** on each written file
  (`FileManager.setAttributes([.modificationDate: item.modifiedAt])`) so
  rsync's size+mtime quick check skips unchanged notes on every push.
- Write `calendar-remote.json` from the given bytes, if any.
- Compute per-file SHA-256 (CryptoKit — VaultKit is Darwin-only, fine),
  sort entries by path, compute `filesDigest`, write `manifest.json`
  (`JSONEncoder` with `.sortedKeys, .prettyPrinted, .iso8601`).
- **Self-check**: `verify(staging: tmp, policy:)`; any violation →
  delete the temp tree and throw `selfCheckFailed` — the previous staging
  image stays untouched and nothing is ever swapped in.
- **Atomic swap**: `staging` → `staging.old-<uuid>` (rename), tmp →
  `staging` (rename), delete old. On a crash between the two renames the
  app finds no `staging` at launch and simply exports again; on launch the
  service (spec 04) deletes any `staging.tmp-*` / `staging.old-*`
  leftovers.
- Staging path for the app: `~/Library/Application Support/Notetaker/RemoteExport/staging`
  (spec 04 passes it; VaultKit takes any URL).

### `writeDisabled`

Builds the image in a temp sibling the same way (only `DISABLED` and
`manifest.json {disabled:true, noteCount:0, files:[], …counts 0}`), then
swaps. The push (spec 04) uses `--delete`, so the container's inbox ends
with exactly those two files.

### Convergence

Export is always a full rebuild; there is no incremental mode. A note that
was unlocked since the last export appears; a note locked since then
disappears from staging (and, via `--delete`, from the replica). Test 2 in
design §5 pins both directions.

## Tests — `Packages/VaultKit/Tests/VaultKitTests/ReplicaExporterTests.swift` (Swift Testing)

Fixture (built per test in a temp root; `VaultKit` test target gains a
dependency on **SecurityKit** so the three locked notes are real
`LockedNoteFile.render` envelopes around `NoteCrypto.encrypt` of
`SENTINEL-LOCKED-9f3a-<n>` with a random salt — the ciphertext strings are
captured for the leak assertions):

- 20 ordinary notes across `/`, `Work/`, `Work/Curriculum/`, `Daily/`
  (some with frontmatter, one CRLF, one with `locked: true` in the body
  text only);
- 3 locked notes (one at root, one nested, one CRLF-rendered by replacing
  `\n` with `\r\n` in the rendered envelope);
- `_index.md` at root and in `Work/`;
- `.DS_Store`, `.Hidden.md.icloud` (zero bytes), `notes.txt`;
- `CLAUDE.md` at root;
- `Work Notes/Personnel/eval.md` (for `excludedFolders`);
- `Private/opt-out.md` with `remote: false`.

Tests:

1. **Nothing locked leaves**: after `export`, walk `staging/vault`: zero
   files contain `locked: true`, any `SENTINEL-LOCKED-9f3a`, or any of the
   three ciphertext strings; `ExportPolicy.looksLocked` is false for every
   file; `manifest.lockedExcludedCount == 3`.
2. **No app files**: no `_index.md` anywhere under staging; nothing hidden;
   `notes.txt` absent; `indexExcludedCount == 2`; `CLAUDE.md` present.
3. **Counts and digest**: `noteCount == files.count == number of files
   under vault/`; every entry's sha256 matches a fresh hash of the file;
   `filesDigest` equals a recomputation; entries sorted by path; JSON keys
   `snake_case`? — **no**: use the `Codable` default (camelCase) and pin it
   with a decode test; spec 06 reads the same `ReplicaManifest` type.
4. **Convergence**: unlock note A (rewrite as plain) → re-export → present;
   lock note B (render envelope) → re-export → absent; counts move 3→2→3.
5. **Scope levers**: with `ExportPolicy(excludedFolders: ["Work Notes/Personnel"])`
   the eval note is absent and `otherExcludedCount` counts it; the
   `remote: false` note is absent regardless of folders.
6. **Calendar passthrough**: `calendarSnapshot: Data("{\"schemaVersion\":1}".utf8)`
   lands byte-identical at `staging/calendar-remote.json`;
   `calendarIncluded == true`; nil → file absent and `false`.
7. **mtime preserved**: set a note's mtime to 2020-01-01, export, staged
   copy has the same mtime (±1 s).
8. **Atomic swap**: export twice; between exports plant `staging/vault/zzz.md`
   by hand; after the second export it is gone (full rebuild) and no
   `staging.tmp-*`/`staging.old-*` siblings remain.
9. **Self-check refuses contaminated output**: call
   `verify(staging:policy:)` on a hand-built staging dir containing a
   locked envelope and a nested `_index.md` → two violations with the right
   reasons; and (via a test-only hook — e.g. an `internal` `beforeSwap`
   closure on the exporter) plant a locked file into the temp tree during
   an export → `export` throws `selfCheckFailed`, the previous staging is
   byte-identical to before (compare manifests), no temp dirs left.
10. **Disabled image**: `writeDisabled` → staging contains exactly
    `DISABLED` and `manifest.json`; manifest `disabled == true`,
    `noteCount == 0`, `files == []`; a following `export` restores the full
    image and `DISABLED` is gone.
11. **Placeholder skipped, not downloaded**: the `.icloud` item is counted
    in `notDownloadedCount` or `otherExcludedCount` (whichever the
    enumerator surfaces — assert the sum) and no download is attempted
    (no call into `VaultFileStore.startDownloading`: make the store
    injectable or assert the placeholder file is untouched).
12. **Parity**: `ExportPolicy.indexFileName == VaultFileStore.indexFileName`
    (the duplicated constant, now checkable because VaultKit imports both).
13. Existing VaultKit tests unchanged and green.

## Acceptance criteria

1. Tests 1–13 green; VaultKit suite green 3× in the gate.
2. `grep -rn "startDownloadingUbiquitousItem\|Process(\|ssh\|rsync" ReplicaExporter.swift` → nothing.
3. The exporter never writes inside `root` (assert in test 8 by hashing the
   fixture tree before/after).
4. Both platform builds green: VaultKit links on iOS too, so
   `ReplicaExporter` must compile there (no AppKit; CryptoKit is fine). If
   `VaultEnumerator`/`VaultItem` need no change on iOS, nothing else does.
5. `scripts/verify.sh 3 --install` green.

## Files expected to change

- `Packages/VaultKit/Package.swift` — add `.package(path: "../MarkdownKit")`
  and the `MarkdownKit` dependency on the `VaultKit` target; add
  `.package(path: "../SecurityKit")` as a **test-target-only** dependency.
- new `Packages/VaultKit/Sources/VaultKit/ReplicaExporter.swift`
- `Packages/VaultKit/Sources/VaultKit/VaultEnumerator.swift` only if the
  index-file counting overload is needed (say so in the PROGRESS row).
- new `Packages/VaultKit/Tests/VaultKitTests/ReplicaExporterTests.swift`
- `Packages/VaultKit/Package.resolved` (new: swift-markdown via MarkdownKit)
- `PROGRESS.md` (one row)

Must not change: `ExportPolicy` (spec 02 owns it — report gaps instead),
`VaultFileStore` semantics, any app file, `project.yml` (the app already
links VaultKit, MarkdownKit and SecurityKit; SwiftPM resolves the new
package edges), docs other than PROGRESS.

## Non-goals

- Pushing anything anywhere; ssh keys; triggers; Settings (spec 04).
- Incremental export, hard links, or rsync-side filtering (the policy is the
  filter; rsync only moves bytes).
- Downloading iCloud placeholders.
- Encrypting the staging dir (it sits in the user's home, same trust level
  as the vault itself).

## Verification commands

```bash
cd ~/Developer/Notetaker/Packages/VaultKit && DEVELOPER_DIR=/Applications/Xcode.app \
  swift test --scratch-path ~/.cache/notetaker-build/VaultKit --filter ReplicaExporterTests
cd ~/Developer/Notetaker && xcodegen generate && swiftformat --lint .
scripts/verify.sh 3 --install   # exit code captured directly
```

## Builder notes

**sonnet.** I/O over a pinned policy with a fixed test list; follow
`IndexFileExclusionTests` for fixture style. `notetaker-swift-reviewer`
before merge (concurrency: the exporter is a `Sendable` struct whose
`export` is `async` only because `VaultFileStore.readString` is; keep it
free of shared mutable state).

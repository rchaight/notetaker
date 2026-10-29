# Spec 02 — `MarkdownKit.ExportPolicy` (the gate that keeps locked notes home)

Design: `00-security-design.md` §1 (what leaves the Mac), §5 (mechanism and
proof, gate 1), §6 (scope-narrowing switches), §7 T2. Builder: **opus**.
Stage: pure — no infrastructure, no app change. First thing to build.

## Scope

A pure, I/O-free value type in MarkdownKit that decides, for one vault file,
whether it may be copied into the remote replica. It is the **only** gate on
the Mac side; `VaultKit.ReplicaExporter` (spec 03) and the container's
`audit-replica` (spec 06) both call it. It must fail **closed**: anything
that looks like a locked note, an app-generated file, a hidden file, or a
file it cannot inspect is excluded. False exclusions are a usability bug;
a false export is a security bug — the asymmetry drives every rule below.

## API

```swift
// Packages/MarkdownKit/Sources/MarkdownKit/ExportPolicy.swift
public enum ExportExclusionReason: String, Sendable, CaseIterable, Codable {
    case invalidPath      // empty, ".." or empty component, absolute, backslash, NUL
    case indexFile        // _index.md at any depth, any letter case
    case hiddenPath       // any path component whose first SCALAR is "."
    case notMarkdown      // extension != md (case-insensitive); covers ".icloud"
    case excludedFolder   // under one of excludedFolders (case-insensitive, per component)
    case undecodable      // bytes are not valid UTF-8, or contain NUL
    case locked           // frontmatter says locked (any non-false value)
    case lockedEnvelope   // salt:/rounds: keys or a bare ciphertext body, i.e. a LockedNoteFile shape
    case optedOut         // frontmatter remote: false
    case unclosedFrontmatterWithLockKey // fail-closed on malformed frontmatter
}

public enum ExportDecision: Equatable, Sendable {
    case export
    case excluded(ExportExclusionReason)
}

public struct ExportPolicy: Sendable, Equatable {
    /// Bump when a rule changes; written into manifest.json as policy_version.
    public static let version = 1
    /// Duplicated from VaultKit.VaultFileStore.indexFileName on purpose —
    /// MarkdownKit cannot import VaultKit. Spec 03 adds a parity test.
    public static let indexFileName = "_index.md"

    /// Vault-relative folder prefixes (e.g. "Work Notes/Personnel").
    /// Normalised on init: trimmed of "/" and whitespace, empty entries dropped.
    public let excludedFolders: [String]

    public init(excludedFolders: [String] = [])

    /// Path-only gate: cheap, run before reading the file.
    public func decide(relativePath: String) -> ExportDecision
    /// Full gate: path gate first, then contents.
    public func decide(relativePath: String, contents: Data) -> ExportDecision
    public func decide(relativePath: String, contents: String) -> ExportDecision

    /// The locked-note detector alone, for self-checks and audit-replica.
    /// True when `decide` would answer .locked, .lockedEnvelope or
    /// .unclosedFrontmatterWithLockKey.
    public static func looksLocked(_ contents: String) -> Bool
}
```

No I/O, no Foundation types beyond `Data`/`String`/`CharacterSet`. Lines are
read lazily with exactly the semantics of the package's `splitLines` +
`strippingCarriageReturn` (`LineSplitting.swift`; eager `splitLines` of a
whole 50 KB note per decision would miss the performance bound) — never
`split(separator: "\n")` (the CRLF-is-one-grapheme trap). **Paths are
split on Unicode scalars, never Characters**: a name beginning with a
combining mark, ZWJ or VS16 (`Private/\u{301}x.md`) glues to the preceding
`/` as one grapheme, and Character-based `split`/`hasPrefix` would miss the
boundary (critique round 2 found this leak on real APFS).

The exporter (spec 03) must never follow symlinks, never read or download
`.icloud` placeholders, and must cap file size before reading (oversize is
an exclusion, not a truncated read); the type's doc comment says so.

## Rules (in order; first match wins)

### Path gate — `decide(relativePath:)`

Components are the path split on the `/` **scalar**.

1. `invalidPath`: empty after trimming `/`; contains `\\`, NUL, a `..`
   component or an empty component (`a//b.md`, `a/b.md/`); first scalar is
   `/`.
2. `hiddenPath`: any component whose first scalar is `.` (covers
   `.DS_Store`, `.Foo.md.icloud`, `.obsidian/x.md`, `.git/…`, `./x.md`,
   `.\u{301}hidden.md`).
3. `indexFile`: last component, lowercased, == `_index.md` (whole name, any
   letter case — on the case-insensitive volume an existing `_Index.md`
   keeps its spelling while the app rewrites it; `index.md`,
   `_index.md.bak`, `Notes_index.md` are not the index file).
4. `notMarkdown`: text after the last component's last `.` scalar,
   lowercased, != `md` (so `Foo.md.icloud`, `notes.txt`, `_index.md.bak`
   are excluded; `Foo.MD` IS markdown).
5. `excludedFolder`: the path's leading components equal all of a
   normalised `excludedFolders` entry's components (so the folder itself or
   anything under it). Components compare **case-insensitively and
   canonically (NFC == NFD)**: equal when `a.compare(b, options:
   .caseInsensitive) == .orderedSame` (full case folding, e.g. `ᾈ` ==
   `ἀι`, as APFS folds) **or** `a.lowercased() == b.lowercased()`; never
   `caseInsensitiveCompare`. The vault is on a case-insensitive APFS volume
   and the folder list is typed by the user, so `work notes/personnel/x.md`
   is under `Work Notes/Personnel`. Normalisation (init): trim `/` and
   whitespace, split on scalars, drop empty and `.` components, resolve `..`
   (an entry escaping the vault is dropped), drop empty entries.
6. otherwise `.export` (the path gate passes `CLAUDE.md` at the root — it
   is a normal note and `vault_overview` wants it).

### Content gate — `decide(relativePath:contents:)`

7. Path gate first; any exclusion returns immediately.
8. `undecodable`: stdlib `String(validating:as: UTF8.self)` fails, **or the
   text contains NUL** → excluded. (A file we cannot read we cannot clear;
   UTF-16/32 without a BOM is valid UTF-8 — ASCII interleaved with NULs —
   and would hide its frontmatter from every rule below.) The `String`
   overload applies the NUL rule too.
9. Normalise for matching only (the policy never rewrites): lines split on
   `\n` with one trailing `\r` stripped; trimming uses whitespace and
   newlines plus BOM/zero-width characters (U+FEFF, U+200B–U+200D, U+2060,
   U+180E), so any number of leading BOMs is ignored. The whole content
   decision is then repeated on a **second line view** that also breaks on
   bare `\r`, VT, FF, NEL, U+2028 and U+2029; if the LF view exports, the
   second view's exclusion (if any) wins.
10. Skip leading **blank** lines. If the first non-blank line, trimmed, is
    exactly `---`: it opens frontmatter. Else there is no frontmatter →
    `.export` (a body that merely contains the text `locked: true` is
    content, not metadata — the "unlocked look-alike" case) — **unless** the
    whole content is a single base64 token of ≥ 40 characters (the body
    `LockedNoteFile.render` writes; AES-GCM output is ≥ 28 bytes) →
    `.lockedEnvelope` (a locked note whose frontmatter was stripped).
11. Frontmatter scan: walk following lines until a line that is **exactly**
    `---` after stripping `\r` — the app's own close (`Frontmatter.split`)
    — or end of file. A line trimmed == `---` or `...` that is not exact is
    a *tolerant* close: remember it, but keep scanning, because the app
    reads past it. Blank and `#` comment lines are skipped. For each other
    line parse `key: value` where key = text before the first `:` trimmed,
    value = text after it trimmed, then stripped of ONE pair of matching
    `"` or `'` quotes, then lowercased. Keys compare case-insensitively and
    also have one pair of quotes stripped. Also read as keys: after leading
    YAML `- ` / `? ` indicators (`? locked` alone is an unknown value →
    locked); every `{`/`}`/`,`-separated segment of a line containing `{`
    (flow mappings at any depth, linear scan); and for `locked:` with an
    empty value, the next indented line is judged as its value.
    - key `locked`: value ∈ {`false`, `no`, `off`, `0`, `""`} → not locked
      by this line; **any other value** (`true`, `yes`, `on`, `1`,
      `maybe`, `"true"`, `TRUE`) → `.locked`. Fail closed on the unknown.
    - key `salt` or `rounds` (any value) → `.lockedEnvelope`.
    - key `remote`: value ∈ {`false`, `no`, `off`, `0`} → `.optedOut`.
    - Precedence if several match: `locked` > `lockedEnvelope` > `optedOut`
      (report the most specific security reason; all exclude anyway).
    - Lines without `:` (other than `? key`) and `#` comment lines are ignored.
12. **Closed** means an exact `---` close within the first 200 lines. Then
    every key line seen applies with rule 11's values and precedence;
    if none excludes and the body after the close is a bare ciphertext
    token (rule 10) → `.lockedEnvelope`; else `.export`.
13. **Not closed** (no exact close, or only after line 200): if a tolerant
    close came within 200 lines and a key line *before* it says `locked` /
    `salt`/`rounds` → `.locked` / `.lockedEnvelope` (keeps the specific
    reason for `...`-fenced notes). Otherwise, if any key line anywhere
    after the opening fence has key `locked` (any value, even `false`),
    `salt` or `rounds` → `.unclosedFrontmatterWithLockKey`; else if any has
    `remote` opt-out → `.optedOut`; else a bare ciphertext body →
    `.lockedEnvelope`; else `.export`. (Critique round 1: lock keys after a
    tolerant close with no exact close used to be dropped —
    `---\n...\nlocked: true\n--` exported.)

What this is deliberately stricter about than the app's own parser
(`Frontmatter.split`, `NoteIndexer`, `VaultService.isLocked`): BOM (any
number), leading blank lines, CRLF in the cheap peek, bare-CR/U+2028/NEL
line ends, quoted/uppercase/yes/unknown values, `...` and trimmed `---`
fences (without ending the scan), indented/`- `/`? `/flow-mapping keys,
envelope keys without `locked`, a bare ciphertext body, NUL/UTF-16 bytes,
and lock keys in frontmatter that never closes. The app never writes those variants
(`LockedNoteFile.render` writes `locked: true` unquoted, LF, first line),
but Obsidian/iOS editors/sync tools can, and the policy's job is to keep
ciphertext *and* the fact of locking at home even then.

## Tests — `Packages/MarkdownKit/Tests/MarkdownKitTests/ExportPolicyTests.swift` (Swift Testing)

Every locked fixture body contains the plaintext sentinel
`SENTINEL-LOCKED-9f3a` so later specs can grep for leaks; this spec's tests
assert decisions, not bytes.

Parameterised table (`@Test(arguments:)`), expected reason in each row:

| group | input | expected |
|---|---|---|
| locked variants | `---\nlocked: true\n---\nSENTINEL…` | locked |
| | `---\nlocked:true\n---\n…` | locked |
| | `---\n"locked": "true"\n---\n…` | locked |
| | `---\nLocked: TRUE\n---\n…` | locked |
| | `---\nlocked: yes\n---\n…` | locked |
| | `---\nlocked: maybe\n---\n…` | locked (fail closed) |
| | `---\r\nlocked: true\r\n---\r\n…` (CRLF) | locked |
| | `\u{FEFF}---\nlocked: true\n---\n…` (BOM) | locked |
| | `\n\n---\nlocked: true\n---\n…` (leading blanks) | locked |
| | `---\ntitle: x\nlocked: true\n...\n…` (`...` fence) | locked |
| | `---\nlocked: true\nsalt: AAAA\n---\n…` | locked (precedence) |
| | `---\nlocked: true\n` + 300 lines, no fence | unclosedFrontmatterWithLockKey |
| | real `LockedNoteFile.render(title:salt:rounds:ciphertext:)` output (hand-rolled in the test with the same template; MarkdownKit cannot import SecurityKit) | locked |
| envelope | `---\nsalt: AAAA\n---\n…` | lockedEnvelope |
| | `---\nrounds: 600000\n---\n…` | lockedEnvelope |
| opt-out | `---\nremote: false\n---\n…` | optedOut |
| | `---\nremote: "no"\n---\n…` | optedOut |
| | `---\nremote: true\n---\n…` | export |
| unlocked look-alikes | `# Note\nlocked: true\n` (no frontmatter) | export |
| | `---\ntitle: a\n---\n\nlocked: true in the body` | export |
| | `---\nlocked: false\n---\n…` | export |
| | `---\nunlocked: true\n---\n…` | export |
| | `---\ntitle: locked: true\n---\n…` (value contains the words) | export |
| | `---\n# locked: true\n---\n…` (comment) | export |
| | `---\ntitle: x\n` + 300 lines no fence, no lock key | export |
| | `` (empty file) | export |
| | plain text with CRLF | export |
| paths | `_index.md`, `Work/_index.md`, `A/B/C/_index.md` | indexFile |
| | `index.md`, `Notes_index.md`, `CLAUDE.md` | export |
| | `_index.md.bak` (was "export" in the first draft; rule 4 excludes it, and a backup TOC lists locked titles) | notMarkdown |
| | `.DS_Store`, `.Foo.md.icloud`, `.obsidian/workspace.md`, `Work/.hidden.md` | hiddenPath |
| | `Foo.md.icloud`, `notes.txt`, `img.png`, `Foo` | notMarkdown |
| | `Foo.MD`, `Foo.Md` | export |
| | `` , `/abs.md`, `../x.md`, `a/../b.md`, `a\\b.md`, `a\u{0}.md` | invalidPath |
| excludedFolders `["Work Notes/Personnel", "/Private/"]` | `Work Notes/Personnel/x.md`, `Work Notes/Personnel/deep/y.md`, `Private/z.md` | excludedFolder |
| | `work notes/personnel/x.md` (was "export" in the first draft; critique round 1 — case-insensitive volume) | excludedFolder |
| | `Work Notes/Personnel.md`, `Work Notes/PersonnelX/x.md` | export |
| excludedFolders `["Private"]` | `Private/\u{301}x.md`, `Private/\u{308}x.md`, `Private/\u{200D}x.md`, `Private/\u{FE0F}x.md`, `Private/Sub/\u{301}x.md` (critique round 2 — scalar components) | excludedFolder |
| | `.\u{301}hidden.md` | hiddenPath |
| undecodable | `Data([0xFF, 0xFE, 0x00, 0x80])` | undecodable |

The test file carries many more rows added by the builder and the two
critique rounds (127 content, 90+ path), notably: `...`/`--- `/indented
`---` before the key with an exact close later → locked; `---\n...\nlocked:
true\n--` and `...`-closed bodies with a lock line → unclosed;
`remote: false` with no exact close → optedOut; CR-only/U+2028/NEL line
ends, double BOM, zero-width before the key → locked; flow mappings,
`- `/`? ` keys, `locked:` + indented value → locked; bare ciphertext body
(with or without replaced frontmatter) → lockedEnvelope; UTF-16/32 without
BOM and any NUL → undecodable; case/NFC/NFD/full-case-fold folder matches.

Plus:
- `looksLocked` agrees with `decide` for every row above (derive from the table).
- `ExportPolicy.version == 1` (so a rule change forces a conscious bump and
  a manifest `policy_version` change).
- Path gate runs before contents: `decide(relativePath: "_index.md",
  contents: "---\nlocked: true\n---")` → `indexFile` (reason precedence for
  the manifest's counters).
- Performance guard: 10,000 decisions on a 50 KB unlocked note < 1 s (keeps
  the exporter's 5-minute cadence cheap; `PerformanceTests.swift` style).
- Fuzz-ish: for 200 random byte strings (seeded RNG), `decide` never traps
  and returns either `undecodable` or a decision — no crash on garbage.

## Acceptance criteria

1. All rows above pass; MarkdownKit suite green 3× under the gate.
2. `ExportPolicy` has no `import` beyond `Foundation`; file contains no
   `FileManager`, `URL(fileURLWithPath:)`, or `Process` (grep).
3. `swiftformat --lint .` clean; iOS and macOS builds green (MarkdownKit is
   linked by the app on both).
4. The locked-variant rows include CRLF and BOM and both pass — this is the
   trap that bit the project before (design §5).

## Files expected to change

- new `Packages/MarkdownKit/Sources/MarkdownKit/ExportPolicy.swift`
- new `Packages/MarkdownKit/Tests/MarkdownKitTests/ExportPolicyTests.swift`
- `PROGRESS.md` (one row)

Must not change: `MarkdownDocument.swift`/`Frontmatter.split` (the editor
round-trips bytes through it; making it tolerant of BOM/blank lines is a
separate decision with editor consequences), `NoteScanner`, any other
package, any app file, docs other than PROGRESS.

## Non-goals

- Reading files, walking directories, writing anything (spec 03).
- Tag-based (`#private`) exclusion or a recency window (design §6 lists
  them as later switches; the `init` can grow parameters without breaking
  callers).
- Changing how the app or `notetaker-mcp` detect locked notes (spec 06
  hardens the server's cheap peek separately).
- YAML parsing beyond shallow `key: value` lines (consistent with
  `Frontmatter`).

## Verification commands

```bash
cd ~/Developer/Notetaker/Packages/MarkdownKit && DEVELOPER_DIR=/Applications/Xcode-beta.app \
  swift test --scratch-path ~/.cache/notetaker-build/MarkdownKit --filter ExportPolicyTests
cd ~/Developer/Notetaker && swiftformat --lint . && xcodegen generate
scripts/verify.sh 3 --install   # before commit; capture its exit code directly, never through a pipe
```

## Builder notes

**opus** — adversarial inputs and a fail-closed contract; the test table is
the spec. If a row's expected value seems wrong, do not change the row:
report it. Add rows freely; never remove one.

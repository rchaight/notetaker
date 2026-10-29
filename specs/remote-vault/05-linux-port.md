# Spec 05 — Linux port of the packages the container needs + Linux CI job

Design: `00-security-design.md` §4.5 (package-by-package assessment),
§7 T1, §9 (keyword-only search; build in-container). Depends on the
calendar work being committed (MCPKit overlap). Builder: sonnet; escalate
to **opus** only if GRDB will not build on Linux (then stop and report —
the SQLite fallback in §4.5 is a separate decision, not this spec).
Stage: 0.

## Scope

Make these packages build and pass their tests on Ubuntu 24.04 x86_64 with
Swift 6.4, **without changing Darwin behaviour**: `TaskEngine`,
`MarkdownKit`, `CalendarKit`, `ProjectKit`, `IndexKit`, `AIKit`, `MCPKit`.
Add a GitHub Actions job that proves it on every push/PR. Everything is
`#if canImport(...)`/`#if os(...)` gating plus one new type
(`NoEmbeddingProvider`); no feature work.

## Design

### Known Darwin-only spots (verified by grep; fix exactly these first, then whatever the Linux compiler adds)

| file | construct | change |
|---|---|---|
| `Packages/IndexKit/Sources/IndexKit/NoteIndexer.swift:1,133` | `import CryptoKit`, `SHA256.hash` | `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`; call site unchanged (swift-crypto mirrors the API) |
| `Packages/IndexKit/Package.swift` | — | add `.package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3")` and `.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))` on the `IndexKit` target |
| `Packages/AIKit/Sources/AIKit/EmbeddingProvider.swift:2` | `import NaturalLanguage`, `AppleEmbeddingProvider` | wrap the import and the whole `AppleEmbeddingProvider` struct in `#if canImport(NaturalLanguage)`; add `public struct NoEmbeddingProvider: EmbeddingProvider` (`isAvailable` → false; `embed` → `throw AIProviderError.unavailable("no embedding provider on this platform")`); add `public enum EmbeddingProviders { public static func platformDefault() -> any EmbeddingProvider }` returning Apple on Darwin, `NoEmbeddingProvider()` elsewhere |
| `Packages/AIKit/Sources/AIKit/OllamaProvider.swift` and any other URLSession user | `URLSession` | `#if canImport(FoundationNetworking) import FoundationNetworking #endif` |
| `Packages/AIKit/Sources/AIKit/FoundationModelsProvider.swift` | already `#if canImport(FoundationModels)` | verify the `#else` path compiles (there may be none needed) |
| `Packages/MCPKit/Sources/MCPKit/VaultService.swift:22` | default arg `AppleEmbeddingProvider()` | `EmbeddingProviders.platformDefault()` |
| `Packages/MCPKit/Sources/MCPKit/VaultFiles.swift:155-200` | `startDownloadingUbiquitousItem`, `.ubiquitousItemDownloadingStatusKey`, `NSFileCoordinator` | `#if canImport(Darwin)` keeps the current code byte-for-byte; `#else`: `ensureDownloaded` = `fileExists` or throw `.notFound`; `coordinatedRead` = `String(contentsOf:encoding:)` on a detached task. Rationale: on the container rsync writes temp files and renames, so an uncoordinated read never sees a torn file (design §4.5) |
| `Packages/MCPKit/Sources/MCPKit/VaultLocation.swift:189-201` | `URL(resolvingBookmarkData:options:.withSecurityScope)` | `#if os(macOS)` the whole `resolveBookmark`; `#else` return nil (registered vaults are a Mac concept; the container always passes `--vault`) |
| `Packages/MCPKit/Tests/MCPKitTests/*` | iCloud placeholder / bookmark / NaturalLanguage-dependent tests | gate those specific tests with `#if os(macOS)`; everything else must run on Linux |
| `Packages/IndexKit` | FTS5 | new test `fts5IsCompiledIn`: `PRAGMA compile_options` contains `ENABLE_FTS5` **or** `CREATE VIRTUAL TABLE t USING fts5(x)` succeeds in an in-memory DB — pins the `libsqlite3` requirement on both platforms |

Rules: Darwin code paths stay textually identical inside the `#if`. No
behaviour is stubbed on Darwin "to make it simpler". Each gate gets a
one-line comment saying why the Linux branch is safe.

### Expected to compile unchanged

`TaskEngine`, `MarkdownKit` (swift-markdown is Linux-native;
`Synchronization` is stdlib), `CalendarKit`, `ProjectKit`. If the compiler
disagrees, gate the same way and list it in the PROGRESS row.

### CI — `.github/workflows/ci.yml`, new job

```yaml
  linux-packages:
    runs-on: ubuntu-24.04
    container: swift:6.4-noble
    steps:
      - uses: actions/checkout@v4
      - name: System deps
        run: apt-get update && apt-get install -y libsqlite3-dev
      - name: Package tests (Linux)
        run: |
          set -euo pipefail
          for PKG in TaskEngine MarkdownKit CalendarKit ProjectKit IndexKit AIKit MCPKit; do
            echo "=== $PKG ==="
            (cd "Packages/$PKG" && swift test)
          done
```

Spec 06 appends `RemoteServer` to that list. Keep the existing macOS jobs
untouched.

## Acceptance criteria

1. The `linux-packages` job is green on a draft PR from the builder's
   branch (link the run in the PROGRESS row). This is the only Linux oracle
   available — no Docker on this Mac (overview, facts).
2. Mac gate unchanged and green: `scripts/verify.sh 3 --install`; every
   existing test still runs on macOS (no test was silently gated out that
   is not genuinely Darwin-only — the row lists each gated test with its
   reason).
3. `grep -rn "canImport(Darwin)\|os(Linux)\|canImport(CryptoKit)\|canImport(NaturalLanguage)\|FoundationNetworking" Packages/{IndexKit,AIKit,MCPKit}/Sources` shows only the spots above plus any the compiler forced, each commented.
4. `VaultService(location:)` on Linux uses `NoEmbeddingProvider`; MCPKit
   test (runs on both platforms): `search(mode: .hybrid)` with
   `NoEmbeddingProvider()` returns `semantic: false` with the existing
   "semantic search unavailable" note — no new code path, just a pin.
5. `fts5IsCompiledIn` passes on both platforms.
6. iOS build green (gates are no-ops there).
7. `Package.resolved` files updated by the Mac toolchain and committed
   (IndexKit, MCPKit — swift-crypto appears).

## Files expected to change

- `Packages/IndexKit/Package.swift`, `Package.resolved`, `Sources/IndexKit/NoteIndexer.swift`, `Tests/IndexKitTests/IndexDatabaseTests.swift` (+1 test)
- `Packages/AIKit/Sources/AIKit/EmbeddingProvider.swift`, `OllamaProvider.swift` (+ others only if the compiler demands), `Tests/AIKitTests/AIKitTests.swift` (+1 `NoEmbeddingProvider` test)
- `Packages/MCPKit/Sources/MCPKit/VaultService.swift`, `VaultFiles.swift`, `VaultLocation.swift`, `Package.resolved`, tests (gates, +1 test)
- `.github/workflows/ci.yml`
- `PROGRESS.md` (one row)

Must not change: `VaultKit`, `EditorKit`, `SecurityKit`, `ConversionKit`,
`ProofKit`, `ReadingKit`, `AppIntentsKit` (not needed on Linux; `SecurityKit`
uses CommonCrypto and the container never decrypts), any App file,
`project.yml`, the MarkdownKit `ExportPolicy` (spec 02).

## Non-goals

- The server itself (spec 06); any Hummingbird or HTTP code.
- The SQLite fallback for GRDB (decision point — report, do not build).
- Static Linux SDK cross-compilation from the Mac (§8.6 → §9: build in-container).
- Making `VaultKit` or `SecurityKit` portable.

## Verification commands

```bash
# Mac side (every package still green)
cd ~/Developer/Notetaker && scripts/verify.sh 3 --install        # exit code captured directly
# Linux side: push the branch and open a draft PR
git push -u origin HEAD && gh pr create --draft --title "Linux port (spec 05)" --body "CI only; do not merge from here."
gh run watch   # until linux-packages is green; paste the run URL in PROGRESS
# (Alternative, user-provided: a build CT per spec 08 §A — builders never ssh to the homelab themselves.)
```

## Builder notes

**sonnet.** Mechanical; the risk is GRDB on Linux. If `swift build` of
IndexKit fails inside the CI container for a GRDB reason (not a missing
`libsqlite3-dev`), stop, paste the first error, and hand back — do not
start the fallback.

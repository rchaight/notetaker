# 05 — Conflict resolution in Release builds

## Goal

The orange conflict badge in the notes list opens a small sheet that resolves an iCloud conflict (Keep mine / Keep the other device's version / Keep both), on Mac and iPhone, in Release. The NSFileVersion work stays in VaultKit behind a testable seam.

## Verified findings

- Badge: `NotesView.swift:2228-2232` shows `exclamationmark.icloud` with help text "Sync conflict — resolve in the Vault tab" and no action. The Vault tab is `#if DEBUG` (`AppShell.swift:181-185, 258-291`); after spec 04 it does not exist on iOS at all. Plan claim correct.
- **Plan correction:** the NSFileVersion logic is **already in VaultKit**: `VaultConflictCenter.unresolvedVersions(for:)` and `resolveKeepingBoth(at:store:)` in `Packages/VaultKit/Sources/VaultKit/Conflicts.swift:74-116`, with `ConflictNaming` for keep-both names. `VaultDebugModel.resolveConflicts` (`App/Debug/VaultDebugModel.swift:81-90`) only calls it (`VaultDebugView.swift:18-23` "Keep Both"). So the work is: add the two missing strategies and a fake-able version source, not a port.
- `VaultItem.hasUnresolvedConflicts` comes from `NSMetadataUbiquitousItemHasUnresolvedConflictsKey` (`MetadataQueryObserver.swift:128-129`), i.e. the badge updates itself once versions are marked resolved. Mac `NotesModel` uses the same observer (`NotesModel.swift:117-123`).
- Existing tests: `ConflictTests.swift` covers naming and `unresolvedVersionsEmptyForLocalFile`; no resolution test (NSFileVersion cannot be fabricated in a temp dir).
- Keep-both copies version contents via `store.copy` then sets `isResolved`, then `removeOtherVersionsOfItem` (`Conflicts.swift:99-114`).

## Design

**VaultKit (`Conflicts.swift`)**

```swift
/// Abstracts NSFileVersion so resolution logic is testable with plain files.
public protocol ConflictVersionSource: Sendable {
    func unresolvedVersions(for url: URL) -> [ConflictVersion]
    func markResolved(_ version: ConflictVersion, of url: URL) throws
    func removeOtherVersions(of url: URL) throws
}
public struct FileVersionSource: ConflictVersionSource { … }   // NSFileVersion-backed, default

public enum ConflictResolution: Sendable, Equatable {
    case keepCurrent                     // my file wins; versions marked resolved
    case keepVersion(ConflictVersion)    // that version's bytes replace the file
    case keepBoth                        // existing behaviour
}
public struct ConflictOutcome: Sendable, Equatable { public let preserved: [URL]; public let resolved: Int }

public struct VaultConflictCenter: Sendable {
    public init(source: any ConflictVersionSource = FileVersionSource())
    public func unresolvedVersions(for url: URL) -> [ConflictVersion]
    public func resolve(_ resolution: ConflictResolution, at url: URL, store: VaultFileStore) async throws -> ConflictOutcome
    /// Kept for VaultDebugModel; forwards to resolve(.keepBoth).
    public func resolveKeepingBoth(at url: URL, store: VaultFileStore) async throws -> [URL]
}
```
- `ConflictVersion` gains `public let id: String` (version URL path) so SwiftUI can list it; keep `contentsURL`, `modificationDate`, `deviceName`.
- `.keepVersion`: read `version.contentsURL` as UTF-8 (`store.readString`), `store.writeString` it to `url` (coordinated, `.forReplacing`), then mark all versions resolved and `removeOtherVersions`. Fail closed: if the read or write throws, mark nothing resolved.
- `.keepCurrent`: mark all resolved, remove other versions, touch nothing else.
- `.keepBoth`: existing code moved under the new API.

**App**

- `App/Notes/ConflictSheet.swift` (new): shows the note title, the current file's modification date, and each version (`deviceName ?? "Other device"`, date). Buttons: "Keep This Device's Copy" (`.keepCurrent`), one "Keep Copy from <device>" per version (`.keepVersion`), "Keep Both as Separate Notes" (`.keepBoth`), Cancel. Before resolving: `await model.flushSave()`; after: `model.reloadIfDisplayed(noteId:)` and `await model.refresh()`. Plain VStack, `.frame` gated per spec 06's helper (no fixed width on iOS), no `.toolbar`.
- `NotesView.syncBadge`: the conflict case becomes a `Button` (plain style) that sets `conflictNote = note`; `.sheet(item: $conflictNote)` presents the sheet; help text "Sync conflict — click to resolve". The row's context menu gets "Resolve Conflict…" for discoverability on iOS (long-press).
- `VaultDebugModel.resolveConflicts`: call `resolve(.keepBoth, …)`; unchanged behaviour.

## Acceptance criteria

1. With a fake source, `resolve(.keepVersion(v))` leaves the file holding `v`'s bytes, all versions marked resolved, `removeOtherVersions` called once; `.keepCurrent` leaves the bytes untouched and marks resolved; `.keepBoth` matches today's naming and copies.
2. A read/write failure during `.keepVersion` marks no version resolved and rethrows.
3. Clicking the orange badge (Mac) or tapping it / "Resolve Conflict…" (iPhone) opens the sheet listing one row per version with device and date.
4. After any resolution the badge disappears within one observer tick and the note shows the chosen content (editor reloads if open).
5. Debug Vault tab "Keep Both" still works on the Mac.

## Files expected to change

`Packages/VaultKit/Sources/VaultKit/Conflicts.swift`, `Packages/VaultKit/Tests/VaultKitTests/ConflictTests.swift` (+ `ConflictResolutionTests.swift` new), `App/Notes/{ConflictSheet.swift (new), NotesView.swift}`, `App/Debug/VaultDebugModel.swift`.
Must NOT touch: `VaultFileStore.swift` (spec 01 edits it; use the existing `readString/writeString/copy`), `MetadataQueryObserver.swift`, `AppShell.swift`.

## Test plan (VaultKit, fake source over temp files)

`FakeVersionSource`: versions are real temp files; records `markResolved` calls and `removeOtherVersions` calls.
- `keepCurrentMarksAllResolvedAndLeavesBytes`
- `keepVersionReplacesContentsThenMarksResolved`
- `keepVersionFailsClosedWhenVersionUnreadable` (contentsURL missing → throws, zero `markResolved`)
- `keepBothPreservesEveryVersionWithNamingRules` (reuses `ConflictNaming` expectations)
- `keepBothThenRemovesOtherVersionsOnce`
- `noVersionsIsNoOp` (no writes, no calls)
- `resolutionOrderIsDeterministic` (versions sorted by date then device)
- Existing `unresolvedVersionsEmptyForLocalFile` stays, against `FileVersionSource`.
Run: `cd Packages/VaultKit && DEVELOPER_DIR=/Applications/Xcode.app swift test --scratch-path ~/.cache/notetaker-build/VaultKit`.

**Manual check (required, cannot be automated):** make a real conflict — put the phone in Airplane Mode, edit the same note on both devices, reconnect — confirm the orange badge appears on both, open the sheet on each device, resolve once with each strategy across three conflicts, confirm the other device converges and no `(conflicted copy)` siblings appear except from Keep Both.

## Non-goals

Three-way merge or diff view, automatic resolution, handling Finder-style `* (conflicted copy).md` sibling files (`ConflictNaming.isConflictedCopyName` exists; a banner for those is a follow-up), resolving conflicts on `_index.md`/non-notes.

## Risks / invariants

- **VaultKit owns file I/O:** the sheet never touches `NSFileVersion`; all writes go through `VaultFileStore`.
- **Files are truth:** Keep mine/other rewrites the vault file under coordination; the index follows from the file change. No index-only state.
- **Locked notes:** a locked note's versions are ciphertext; the sheet shows no bodies, so nothing leaks. Keep Both copies ciphertext files, which is correct.
- Autosave: flush before resolving; otherwise the pending buffer could overwrite the chosen version 800 ms later.

## Builder model

sonnet.

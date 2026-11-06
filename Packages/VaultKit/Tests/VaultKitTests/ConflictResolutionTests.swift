import Foundation
import Testing
@testable import VaultKit

/// NSFileVersion conflict versions cannot be fabricated in a temp dir, so resolution runs
/// against `FakeVersionSource`: versions are real temp files, and every `markResolved` /
/// `removeOtherVersions` call is recorded. Spec: specs/ux-phase1/05-release-conflict-resolver.md.
final class FakeVersionSource: ConflictVersionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [ConflictVersion]
    private var resolvedIds: [String] = []
    private var removeCalls = 0

    init(versions: [ConflictVersion]) {
        self.versions = versions
    }

    var markResolvedIds: [String] {
        lock.withLock { resolvedIds }
    }

    var removeOtherVersionsCalls: Int {
        lock.withLock { removeCalls }
    }

    func unresolvedVersions(for _: URL) -> [ConflictVersion] {
        lock.withLock { versions.filter { !resolvedIds.contains($0.id) } }
    }

    func markResolved(_ version: ConflictVersion, of _: URL) throws {
        lock.withLock { resolvedIds.append(version.id) }
    }

    func removeOtherVersions(of _: URL) throws {
        lock.withLock { removeCalls += 1 }
    }
}

struct ConflictResolutionTests {
    private struct Fixture {
        let root: URL
        let note: URL
        let store: VaultFileStore
    }

    private func makeFixture(current: String = "mine") async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConflictResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultFileStore()
        let note = root.appendingPathComponent("Note.md")
        try await store.writeString(current, to: note)
        return Fixture(root: root, note: note, store: store)
    }

    /// A version whose bytes are a real file next to the fixture (the "version store").
    private func makeVersion(
        _ fixture: Fixture, name: String, contents: String?, device: String?, date: Date?
    ) throws -> ConflictVersion {
        let url = fixture.root.appendingPathComponent(".versions/\(name).md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return ConflictVersion(contentsURL: url, modificationDate: date, deviceName: device)
    }

    private func siblings(_ fixture: Fixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    @Test func keepCurrentMarksAllResolvedAndLeavesBytes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try makeVersion(
            fixture,
            name: "a",
            contents: "theirs A",
            device: "iPhone",
            date: Date(timeIntervalSince1970: 100)
        )
        let b = try makeVersion(
            fixture,
            name: "b",
            contents: "theirs B",
            device: "iPad",
            date: Date(timeIntervalSince1970: 200)
        )
        let source = FakeVersionSource(versions: [a, b])
        let center = VaultConflictCenter(source: source)

        let outcome = try await center.resolve(.keepCurrent, at: fixture.note, store: fixture.store)

        #expect(try await fixture.store.readString(at: fixture.note) == "mine")
        #expect(Set(source.markResolvedIds) == [a.id, b.id])
        #expect(source.markResolvedIds.count == 2)
        #expect(source.removeOtherVersionsCalls == 1)
        #expect(outcome == ConflictOutcome(preserved: [], resolved: 2))
        #expect(try siblings(fixture) == ["Note.md"])
    }

    @Test func keepVersionReplacesContentsThenMarksResolved() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try makeVersion(
            fixture,
            name: "a",
            contents: "theirs A",
            device: "iPhone",
            date: Date(timeIntervalSince1970: 100)
        )
        let b = try makeVersion(
            fixture,
            name: "b",
            contents: "# Theirs B\n\n- [ ] task ✅2026-07-14\n",
            device: "iPad",
            date: Date(timeIntervalSince1970: 200)
        )
        let source = FakeVersionSource(versions: [a, b])
        let center = VaultConflictCenter(source: source)

        let outcome = try await center.resolve(.keepVersion(b), at: fixture.note, store: fixture.store)

        #expect(try await fixture.store.readString(at: fixture.note) == "# Theirs B\n\n- [ ] task ✅2026-07-14\n")
        // Every version is settled, including the one not chosen, and the store is pruned once.
        #expect(Set(source.markResolvedIds) == [a.id, b.id])
        #expect(source.removeOtherVersionsCalls == 1)
        #expect(outcome == ConflictOutcome(preserved: [], resolved: 2))
        #expect(try siblings(fixture) == ["Note.md"])
    }

    @Test func keepVersionFailsClosedWhenVersionUnreadable() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // contents: nil → the version's file does not exist.
        let missing = try makeVersion(fixture, name: "gone", contents: nil, device: "iPhone", date: nil)
        let other = try makeVersion(fixture, name: "other", contents: "theirs", device: "iPad", date: nil)
        let source = FakeVersionSource(versions: [missing, other])
        let center = VaultConflictCenter(source: source)

        await #expect(throws: Error.self) {
            _ = try await center.resolve(.keepVersion(missing), at: fixture.note, store: fixture.store)
        }

        #expect(source.markResolvedIds.isEmpty)
        #expect(source.removeOtherVersionsCalls == 0)
        #expect(try await fixture.store.readString(at: fixture.note) == "mine")
    }

    @Test func keepVersionFailsClosedWhenWriteFails() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let version = try makeVersion(fixture, name: "a", contents: "theirs", device: "iPhone", date: nil)
        let source = FakeVersionSource(versions: [version])
        let center = VaultConflictCenter(source: source)
        // "Note.md" is a FILE, so "Note.md/inner.md" can never be created.
        let unwritable = fixture.note.appendingPathComponent("inner.md")

        await #expect(throws: Error.self) {
            _ = try await center.resolve(.keepVersion(version), at: unwritable, store: fixture.store)
        }

        #expect(source.markResolvedIds.isEmpty)
        #expect(source.removeOtherVersionsCalls == 0)
        #expect(try await fixture.store.readString(at: fixture.note) == "mine")
    }

    @Test func keepBothPreservesEveryVersionWithNamingRules() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let dateA = Date(timeIntervalSince1970: 1_780_000_000)
        let dateB = Date(timeIntervalSince1970: 1_780_100_000)
        let a = try makeVersion(fixture, name: "a", contents: "theirs A", device: "iPhone", date: dateA)
        let b = try makeVersion(fixture, name: "b", contents: "theirs B", device: "iPhone", date: dateA) // same stamp
        let c = try makeVersion(fixture, name: "c", contents: "theirs C", device: nil, date: dateB)
        let source = FakeVersionSource(versions: [a, b, c])
        let center = VaultConflictCenter(source: source)

        let outcome = try await center.resolve(.keepBoth, at: fixture.note, store: fixture.store)

        // Expected names come from the same naming rules, accumulating as the center does.
        var existing = Set(["Note.md"])
        var expected: [String] = []
        for version in [a, b, c] {
            let name = ConflictNaming.keepBothName(
                original: "Note.md", device: version.deviceName, date: version.modificationDate, existing: existing
            )
            existing.insert(name)
            expected.append(name)
        }
        #expect(outcome.preserved.map(\.lastPathComponent) == expected)
        #expect(outcome.resolved == 3)
        #expect(Set(expected).count == 3) // the identical device+date pair got a counter
        let contents = try await [
            fixture.store.readString(at: fixture.root.appendingPathComponent(expected[0])),
            fixture.store.readString(at: fixture.root.appendingPathComponent(expected[1])),
            fixture.store.readString(at: fixture.root.appendingPathComponent(expected[2])),
        ]
        #expect(contents == ["theirs A", "theirs B", "theirs C"])
        // The current file is untouched.
        #expect(try await fixture.store.readString(at: fixture.note) == "mine")
        #expect(Set(source.markResolvedIds) == [a.id, b.id, c.id])
    }

    @Test func keepBothThenRemovesOtherVersionsOnce() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try makeVersion(fixture, name: "a", contents: "A", device: "iPhone", date: nil)
        let b = try makeVersion(fixture, name: "b", contents: "B", device: "iPad", date: nil)
        let source = FakeVersionSource(versions: [a, b])

        _ = try await VaultConflictCenter(source: source).resolve(.keepBoth, at: fixture.note, store: fixture.store)

        #expect(source.removeOtherVersionsCalls == 1)
        #expect(source.markResolvedIds.count == 2)
    }

    @Test func keepBothNamesTheSingleConflictCopyAfterItsDevice() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try makeVersion(fixture, name: "a", contents: "A", device: "iPhone", date: nil)
        let source = FakeVersionSource(versions: [a])

        let preserved = try await VaultConflictCenter(source: source)
            .resolve(.keepBoth, at: fixture.note, store: fixture.store).preserved

        #expect(preserved.map(\.lastPathComponent) == ["Note (conflict from iPhone).md"])
        #expect(source.markResolvedIds == [a.id])
    }

    @Test func noVersionsIsNoOp() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = FakeVersionSource(versions: [])
        let center = VaultConflictCenter(source: source)

        for resolution in [ConflictResolution.keepCurrent, .keepBoth] {
            let outcome = try await center.resolve(resolution, at: fixture.note, store: fixture.store)
            #expect(outcome == ConflictOutcome(preserved: [], resolved: 0))
        }
        let phantom = ConflictVersion(
            contentsURL: fixture.root.appendingPathComponent("nope.md"), modificationDate: nil, deviceName: nil
        )
        _ = try await center.resolve(.keepVersion(phantom), at: fixture.note, store: fixture.store)

        #expect(source.markResolvedIds.isEmpty)
        #expect(source.removeOtherVersionsCalls == 0)
        #expect(try await fixture.store.readString(at: fixture.note) == "mine")
        #expect(try siblings(fixture) == ["Note.md"])
    }

    @Test func resolutionOrderIsDeterministic() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 900)
        let lateIPad = try makeVersion(fixture, name: "1", contents: "1", device: "iPad", date: late)
        let lateIPhone = try makeVersion(fixture, name: "2", contents: "2", device: "iPhone", date: late)
        let earlyMac = try makeVersion(fixture, name: "3", contents: "3", device: "Mac", date: early)
        let undated = try makeVersion(fixture, name: "4", contents: "4", device: "Mac", date: nil)
        let unnamedLate = try makeVersion(fixture, name: "5", contents: "5", device: nil, date: late)

        let shuffles = [
            [undated, lateIPhone, earlyMac, unnamedLate, lateIPad],
            [lateIPad, unnamedLate, undated, earlyMac, lateIPhone],
            [earlyMac, lateIPad, lateIPhone, undated, unnamedLate],
        ]
        for versions in shuffles {
            let center = VaultConflictCenter(source: FakeVersionSource(versions: versions))
            // Oldest first, then device name (unnamed last); undated sorts after dated.
            #expect(center.unresolvedVersions(for: fixture.note).map(\.id)
                == [earlyMac, lateIPad, lateIPhone, unnamedLate, undated].map(\.id))
        }

        // The sorted order is what keep-both names and writes, whatever order the source returns.
        let source = FakeVersionSource(versions: shuffles[0])
        let outcome = try await VaultConflictCenter(source: source)
            .resolve(.keepBoth, at: fixture.note, store: fixture.store)
        #expect(source.markResolvedIds == [earlyMac, lateIPad, lateIPhone, unnamedLate, undated].map(\.id))
        #expect(outcome.preserved.count == 5)
    }

    @Test func conflictVersionIdIsItsContentsPath() {
        let url = URL(fileURLWithPath: "/tmp/versions/abc.md")
        let version = ConflictVersion(contentsURL: url, modificationDate: nil, deviceName: nil)
        #expect(version.id == "/tmp/versions/abc.md")
    }
}

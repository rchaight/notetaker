import Foundation
import MCP
@testable import RemoteServerCore
import Testing

struct ReplicaWatcherTests {
    @Test func noManifestIsEmpty() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        let watcher = try await fixture.readyWatcher()
        let snapshot = await watcher.current()
        #expect(snapshot.state == .empty)
        #expect(snapshot.service == nil)
    }

    @Test func consistentPushIsReadyAndServedFromTheIndex() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        let manifest = try fixture.push()
        let watcher = try await fixture.readyWatcher()
        let snapshot = await watcher.current()
        guard case let .ready(generatedAt, ready) = snapshot.state else {
            Issue.record("expected ready, got \(snapshot.state)")
            return
        }
        #expect(generatedAt == manifest.generatedAt)
        #expect(ready.noteCount == ReplicaFixture.notes.count)
        let overview = snapshot.service?.vaultOverview()
        #expect(overview?["source"]?.stringValue == "index")
        #expect(overview?["note_count"]?.intValue == ReplicaFixture.notes.count)
        #expect(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("index.sqlite").path))
        // No half-built index left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.state.path)
            .filter { $0.hasPrefix("index.tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func disabledManifestDropsTheServiceAndTheIndex() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let watcher = try await fixture.readyWatcher()
        #expect(await watcher.current().service != nil)

        try fixture.push(disabled: true)
        await watcher.tick()
        let snapshot = await watcher.current()
        #expect(snapshot.state == .disabled)
        #expect(snapshot.service == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("index.sqlite").path))
    }

    @Test func disabledMarkerFileAloneDisables() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let watcher = try await fixture.readyWatcher()
        FileManager.default.createFile(
            atPath: fixture.replica.appendingPathComponent("DISABLED").path,
            contents: Data()
        )
        await watcher.tick()
        #expect(await watcher.current().state == .disabled)
        #expect(await watcher.current().service == nil)
    }

    @Test func digestMismatchIsInconsistentAndThePreviousServiceKeepsAnswering() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let watcher = try await fixture.readyWatcher()

        // A newer manifest lands, but one file is not the bytes it names.
        try fixture.push(generatedAt: Date(timeIntervalSince1970: 1_787_100_000), tamper: ["Inbox.md": "# partial"])
        await watcher.tick()
        let snapshot = await watcher.current()
        guard case .inconsistent = snapshot.state else {
            Issue.record("expected inconsistent, got \(snapshot.state)")
            return
        }
        #expect(snapshot.service != nil)
        #expect(snapshot.servedGeneratedAt == Date(timeIntervalSince1970: 1_787_000_000))
        let overview = snapshot.service?.vaultOverview()
        #expect(overview?["note_count"]?.intValue == ReplicaFixture.notes.count)

        // The push completes: the next tick recovers without a manifest change.
        try fixture.push(generatedAt: Date(timeIntervalSince1970: 1_787_100_000))
        await watcher.tick()
        guard case .ready = await watcher.current().state else {
            Issue.record("expected ready after the push completed")
            return
        }
    }

    @Test func extraMarkdownNotInTheManifestIsInconsistent() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push(stray: ["Secret/Stray.md": "# not listed"])
        let watcher = try await fixture.readyWatcher()
        guard case .inconsistent = await watcher.current().state else {
            Issue.record("expected inconsistent")
            return
        }
        #expect(await watcher.current().service == nil)
    }

    @Test func secondPushWithAChangedNoteIsReflected() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        try fixture.push()
        let watcher = try await fixture.readyWatcher()
        let before = try await #require(await watcher.current().service).search(
            query: "zebra",
            mode: .keyword,
            limit: 5
        )
        #expect(before["results"]?.arrayValue?.isEmpty == true)

        var changed = ReplicaFixture.notes
        changed["Inbox.md"] = "# Inbox\nzebra crossing audit\n"
        try fixture.push(notes: changed, generatedAt: Date(timeIntervalSince1970: 1_787_200_000))
        await watcher.tick()
        let service = try #require(await watcher.current().service)
        let after = await service.search(query: "zebra", mode: .keyword, limit: 5)
        #expect(after["source"]?.stringValue == "index")
        #expect(after["results"]?.arrayValue?.first?["path"]?.stringValue == "Inbox.md")
    }

    @Test func manifestPathsCannotEscapeTheVault() async throws {
        let fixture = try ReplicaFixture()
        defer { fixture.cleanUp() }
        let evil = ReplicaManifest(
            generatedAt: Date(), files: [.init(path: "../manifest.json", sha256: "00", bytes: 1)]
        )
        try evil.encoded().write(to: fixture.replica.appendingPathComponent("manifest.json"))
        let watcher = try await fixture.readyWatcher()
        guard case .inconsistent = await watcher.current().state else {
            Issue.record("expected inconsistent")
            return
        }
    }
}

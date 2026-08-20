import Foundation
import Testing
@testable import VaultKit

/// `_index.md` is the app's own auto-generated per-folder table of
/// contents (spec `mcp/01-context-files.md`) — it must never surface as a
/// note anywhere. These tests pin the exclusion at VaultKit's enumeration
/// choke point so the app-target consumers (indexer, notes list, recents,
/// search, task extraction) all inherit it for free.
struct IndexFileExclusionTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexFileExclusionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func isIndexFileMatchesOnlyTheExactName() {
        #expect(VaultFileStore.isIndexFile("_index.md"))
        #expect(VaultFileStore.isIndexFile("Meetings/_index.md"))
        #expect(VaultFileStore.isIndexFile("A/B/C/_index.md"))
        #expect(!VaultFileStore.isIndexFile("index.md"))
        #expect(!VaultFileStore.isIndexFile("_index.md.bak"))
        #expect(!VaultFileStore.isIndexFile("CLAUDE.md"))
        #expect(!VaultFileStore.isIndexFile("Meetings/Notes_index.md"))
    }

    @Test func enumeratorSnapshotSkipsIndexFilesAtRootAndNestedFolders() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        try await store.writeString("toc", to: root.appendingPathComponent("_index.md"))
        try await store.writeString("toc", to: root.appendingPathComponent("Meetings/_index.md"))
        try await store.writeString("real note", to: root.appendingPathComponent("Meetings/Bob.md"))
        try await store.writeString("root note", to: root.appendingPathComponent("CLAUDE.md"))

        let paths = Set(VaultEnumerator.snapshot(of: root).map(\.relativePath))
        #expect(!paths.contains("_index.md"))
        #expect(!paths.contains("Meetings/_index.md"))
        #expect(paths.contains("Meetings/Bob.md"))
        #expect(paths.contains("CLAUDE.md"))
        // The folder itself is still enumerated — only the file is dropped.
        #expect(paths.contains("Meetings"))
    }
}

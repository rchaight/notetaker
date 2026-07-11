import Foundation
import Testing
@testable import VaultKit

struct VaultFolderTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func folderCreateRenameDelete() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try await store.createFolder(at: folder)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        let renamed = root.appendingPathComponent("Archive", isDirectory: true)
        try await store.move(from: folder, to: renamed)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: renamed.path))

        try await store.delete(at: renamed)
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func movingFolderCarriesContents() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        try await store.writeString("keep me", to: root.appendingPathComponent("Old/nested/note.md"))
        try await store.move(
            from: root.appendingPathComponent("Old"),
            to: root.appendingPathComponent("New")
        )
        let contents = try await store.readString(at: root.appendingPathComponent("New/nested/note.md"))
        #expect(contents == "keep me")
    }

    @Test func enumeratorSnapshotsTree() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        try await store.writeString("a", to: root.appendingPathComponent("a.md"))
        try await store.writeString("b", to: root.appendingPathComponent("Sub/b.md"))

        let items = VaultEnumerator.snapshot(of: root)
        let paths = items.map(\.relativePath)
        #expect(paths == ["Sub", "Sub/b.md", "a.md"])
        #expect(items.first { $0.relativePath == "Sub" }?.isDirectory == true)
        #expect(items.first { $0.relativePath == "a.md" }?.isDirectory == false)
    }

    @Test func enumeratorToleratesDanglingSymlink() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        try await store.writeString("real", to: root.appendingPathComponent("real.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling.md"),
            withDestinationURL: root.appendingPathComponent("does-not-exist.md")
        )

        let items = VaultEnumerator.snapshot(of: root)
        #expect(items.contains { $0.relativePath == "real.md" })
    }

    @Test func enumeratorOfMissingRootIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-created-\(UUID().uuidString)")
        #expect(VaultEnumerator.snapshot(of: missing).isEmpty)
    }

    @Test func externalUncoordinatedDeletionDoesNotBreakStore() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let note = root.appendingPathComponent("victim.md")

        try await store.writeString("here now", to: note)
        // Simulate Files.app/Obsidian deleting behind our back — no coordination.
        try FileManager.default.removeItem(at: note)

        await #expect(throws: Error.self) {
            _ = try await store.readString(at: note)
        }
        // Store stays usable afterwards.
        try await store.writeString("recovered", to: note)
        let contents = try await store.readString(at: note)
        #expect(contents == "recovered")
    }
}

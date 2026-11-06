import Foundation
import Testing
@testable import VaultKit

/// Spec: specs/ux-phase1/01-trash-and-delete-confirmations.md. The Trash is a hidden folder
/// in the vault and nothing else — every test here reads the real files back.
struct VaultTrashTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultTrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ root: URL, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    @Test func trashMovesIntoHiddenFolderPreservingSubpath() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("plan", to: root.appendingPathComponent("Work/Deep/Plan.md"))

        let receipt = try await VaultTrash.trash(relativePath: "Work/Deep/Plan.md", in: root, store: store)

        #expect(receipt.originalPath == "Work/Deep/Plan.md")
        #expect(receipt.trashedPath == ".trash/Work/Deep/Plan.md")
        #expect(!exists(root, "Work/Deep/Plan.md"))
        #expect(exists(root, ".trash/Work/Deep/Plan.md"))
        // The folder the note lived in is the user's; trashing never removes it.
        #expect(exists(root, "Work/Deep"))
    }

    @Test func trashUniquifiesOnCollision() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        try await store.writeString("first", to: root.appendingPathComponent("Note.md"))
        let first = try await VaultTrash.trash(relativePath: "Note.md", in: root, store: store)
        try await store.writeString("second", to: root.appendingPathComponent("Note.md"))
        let second = try await VaultTrash.trash(relativePath: "Note.md", in: root, store: store)
        try await store.writeString("third", to: root.appendingPathComponent("Note.md"))
        let third = try await VaultTrash.trash(relativePath: "Note.md", in: root, store: store)

        #expect(first.trashedPath == ".trash/Note.md")
        #expect(second.trashedPath == ".trash/Note 2.md")
        #expect(third.trashedPath == ".trash/Note 3.md")
        // Receipts keep the original name, so each Undo goes back to Note.md.
        #expect(second.originalPath == "Note.md")
        let firstText = try await store.readString(at: root.appendingPathComponent(first.trashedPath))
        let secondText = try await store.readString(at: root.appendingPathComponent(second.trashedPath))
        #expect(firstText == "first")
        #expect(secondText == "second")
    }

    @Test func restoreReturnsToOriginalPath() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("body", to: root.appendingPathComponent("Folder/Note.md"))
        let receipt = try await VaultTrash.trash(relativePath: "Folder/Note.md", in: root, store: store)

        let restored = try await VaultTrash.restore(receipt.entry, in: root, store: store)

        #expect(restored == "Folder/Note.md")
        #expect(exists(root, "Folder/Note.md"))
        #expect(!exists(root, ".trash/Folder/Note.md"))
        #expect(try await store.readString(at: root.appendingPathComponent(restored)) == "body")
    }

    @Test func restoreRecreatesAFolderThatWasDeleted() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("body", to: root.appendingPathComponent("Gone/Note.md"))
        let receipt = try await VaultTrash.trash(relativePath: "Gone/Note.md", in: root, store: store)
        try await store.delete(at: root.appendingPathComponent("Gone"))

        let restored = try await VaultTrash.restore(receipt.entry, in: root, store: store)

        #expect(restored == "Gone/Note.md")
        #expect(exists(root, "Gone/Note.md"))
    }

    @Test func restoreUniquifiesWhenOriginalTaken() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("old", to: root.appendingPathComponent("Note.md"))
        let receipt = try await VaultTrash.trash(relativePath: "Note.md", in: root, store: store)
        try await store.writeString("new", to: root.appendingPathComponent("Note.md"))

        let restored = try await VaultTrash.restore(receipt.entry, in: root, store: store)

        #expect(restored == "Note 2.md")
        // Neither note was overwritten.
        #expect(try await store.readString(at: root.appendingPathComponent("Note.md")) == "new")
        #expect(try await store.readString(at: root.appendingPathComponent("Note 2.md")) == "old")
    }

    @Test func purgeRemovesOnlyThatEntry() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("a", to: root.appendingPathComponent("A.md"))
        try await store.writeString("b", to: root.appendingPathComponent("Sub/B.md"))
        let receiptA = try await VaultTrash.trash(relativePath: "A.md", in: root, store: store)
        _ = try await VaultTrash.trash(relativePath: "Sub/B.md", in: root, store: store)

        try await VaultTrash.purge(receiptA.entry, in: root, store: store)

        #expect(!exists(root, ".trash/A.md"))
        #expect(exists(root, ".trash/Sub/B.md"))
        #expect(VaultTrash.list(in: root).map(\.trashedPath) == [".trash/Sub/B.md"])
    }

    @Test func emptyRemovesEverything() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        for path in ["A.md", "Sub/B.md", "Sub/Deep/C.md"] {
            try await store.writeString("x", to: root.appendingPathComponent(path))
            _ = try await VaultTrash.trash(relativePath: path, in: root, store: store)
        }
        try await store.writeString("keep", to: root.appendingPathComponent("Keep.md"))
        #expect(VaultTrash.list(in: root).count == 3)

        try await VaultTrash.empty(in: root, store: store)

        #expect(VaultTrash.list(in: root).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".trash").path).isEmpty)
        #expect(exists(root, "Keep.md"))
        // Emptying a vault that never had a Trash is a no-op, not an error.
        let fresh = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: fresh) }
        try await VaultTrash.empty(in: fresh, store: store)
    }

    @Test func listReturnsMdNewestFirst() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let trashFolder = root.appendingPathComponent(".trash/Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        func put(_ path: String, daysAgo: Double) throws {
            let url = root.appendingPathComponent(path)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -daysAgo * 86400)],
                ofItemAtPath: url.path
            )
        }
        try put(".trash/Old.md", daysAgo: 10)
        try put(".trash/Sub/Newer.md", daysAgo: 2)
        try put(".trash/Newest.MD", daysAgo: 1)
        try put(".trash/readme.txt", daysAgo: 0) // not a note
        try put(".trash/.DS_Store", daysAgo: 0) // Finder litter
        try put(".trash/.Pending.md.icloud", daysAgo: 5) // undownloaded placeholder

        let entries = VaultTrash.list(in: root)

        #expect(entries.map(\.trashedPath) == [
            ".trash/Newest.MD", ".trash/Sub/Newer.md", ".trash/Pending.md", ".trash/Old.md",
        ])
        #expect(entries.map(\.originalPath) == ["Newest.MD", "Sub/Newer.md", "Pending.md", "Old.md"])
        #expect(entries.allSatisfy { $0.modificationDate != nil })
        #expect(entries.first?.id == ".trash/Newest.MD")
        // A vault with no Trash lists nothing.
        let fresh = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: fresh) }
        #expect(VaultTrash.list(in: fresh).isEmpty)
        _ = store
    }

    @Test func trashedFileKeepsBytesAndFrontmatter() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let body = "---\nfavorite: true\narea: Work\ntags: [a, b]\n---\n# Title\r\n\n- [ ] task >friday !p1 ✅2026-07-14\n"
        let url = root.appendingPathComponent("Note.md")
        try await store.writeString(body, to: url)
        let before = try Data(contentsOf: url)

        let receipt = try await VaultTrash.trash(relativePath: "Note.md", in: root, store: store)
        #expect(try Data(contentsOf: root.appendingPathComponent(receipt.trashedPath)) == before)

        let restored = try await VaultTrash.restore(receipt.entry, in: root, store: store)
        #expect(try Data(contentsOf: root.appendingPathComponent(restored)) == before)
    }

    @Test func restoreRemovesEmptyTrashSubfolders() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("a", to: root.appendingPathComponent("A/B/One.md"))
        try await store.writeString("b", to: root.appendingPathComponent("A/Two.md"))
        let one = try await VaultTrash.trash(relativePath: "A/B/One.md", in: root, store: store)
        let two = try await VaultTrash.trash(relativePath: "A/Two.md", in: root, store: store)

        _ = try await VaultTrash.restore(one.entry, in: root, store: store)
        // .trash/A/B is gone, .trash/A still holds Two.md.
        #expect(!exists(root, ".trash/A/B"))
        #expect(exists(root, ".trash/A/Two.md"))

        try await VaultTrash.purge(two.entry, in: root, store: store)
        #expect(!exists(root, ".trash/A"))
        // The Trash folder itself stays.
        #expect(exists(root, ".trash"))
    }

    @Test func moveCoordinatesDestination() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let source = root.appendingPathComponent("old/name.md")
        try await store.writeString("moving", to: source)

        // The destination folder is created first, under coordination.
        let fresh = root.appendingPathComponent("brand/new/folder/name.md")
        try await store.move(from: source, to: fresh)
        #expect(try await store.readString(at: fresh) == "moving")
        #expect(!FileManager.default.fileExists(atPath: source.path))

        // Moving onto an existing file never overwrites it: the move throws and both files
        // are intact (the Notes "Move To" menu relies on this; data loss is never silent).
        let occupied = root.appendingPathComponent("taken.md")
        try await store.writeString("already here", to: occupied)
        await #expect(throws: Error.self) {
            try await store.move(from: fresh, to: occupied)
        }
        #expect(try await store.readString(at: occupied) == "already here")
        #expect(try await store.readString(at: fresh) == "moving")
    }

    @Test func invalidPathsAreRejectedAndNothingMoves() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("x", to: root.appendingPathComponent("Note.md"))
        try await store.writeString("x", to: root.appendingPathComponent("Folder/Note.md"))

        for bad in ["", "/abs.md", "../escape.md", "a/../b.md", "a//b.md", "./x.md"] {
            await #expect(throws: VaultTrashError.self) {
                _ = try await VaultTrash.trash(relativePath: bad, in: root, store: store)
            }
        }
        // Already trashed, and folders, are refused.
        await #expect(throws: VaultTrashError.alreadyInTrash(".trash/x.md")) {
            _ = try await VaultTrash.trash(relativePath: ".trash/x.md", in: root, store: store)
        }
        await #expect(throws: VaultTrashError.notAFile("Folder")) {
            _ = try await VaultTrash.trash(relativePath: "Folder", in: root, store: store)
        }
        #expect(exists(root, "Note.md"))
        #expect(exists(root, "Folder/Note.md"))
    }

    @Test func purgeAndRestoreRefuseEntriesOutsideTheTrash() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        try await store.writeString("precious", to: root.appendingPathComponent("Note.md"))

        let outside = VaultTrash.Entry(trashedPath: "Note.md", originalPath: "Note.md", modificationDate: nil)
        let traversal = VaultTrash.Entry(
            trashedPath: ".trash/../Note.md", originalPath: "Note.md", modificationDate: nil
        )
        for entry in [outside, traversal] {
            await #expect(throws: VaultTrashError.self) {
                try await VaultTrash.purge(entry, in: root, store: store)
            }
            await #expect(throws: VaultTrashError.self) {
                _ = try await VaultTrash.restore(entry, in: root, store: store)
            }
        }
        // A tampered original path cannot escape the vault either.
        try await store.writeString("x", to: root.appendingPathComponent(".trash/Inside.md"))
        let escaping = VaultTrash.Entry(
            trashedPath: ".trash/Inside.md", originalPath: "../Inside.md", modificationDate: nil
        )
        await #expect(throws: VaultTrashError.self) {
            _ = try await VaultTrash.restore(escaping, in: root, store: store)
        }
        #expect(try await store.readString(at: root.appendingPathComponent("Note.md")) == "precious")
        #expect(exists(root, ".trash/Inside.md"))
    }
}

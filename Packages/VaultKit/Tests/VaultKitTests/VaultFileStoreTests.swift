import Foundation
import Testing
@testable import VaultKit

struct VaultFileStoreTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writeReadRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let note = root.appendingPathComponent("Inbox/note.md")

        try await store.writeString("# Hello\n\n- [ ] task", to: note)
        let contents = try await store.readString(at: note)
        #expect(contents == "# Hello\n\n- [ ] task")
    }

    @Test func writeCreatesIntermediateFolders() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let nested = root.appendingPathComponent("a/b/c/deep.md")

        try await store.writeString("deep", to: nested)
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test func overwriteReplacesContents() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let note = root.appendingPathComponent("note.md")

        try await store.writeString("v1", to: note)
        try await store.writeString("v2", to: note)
        let contents = try await store.readString(at: note)
        #expect(contents == "v2")
    }

    @Test func deleteRemovesFile() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let note = root.appendingPathComponent("gone.md")

        try await store.writeString("bye", to: note)
        try await store.delete(at: note)
        #expect(!FileManager.default.fileExists(atPath: note.path))
    }

    @Test func moveRelocatesFile() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let source = root.appendingPathComponent("old/name.md")
        let destination = root.appendingPathComponent("new/renamed.md")

        try await store.writeString("moving", to: source)
        try await store.move(from: source, to: destination)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let contents = try await store.readString(at: destination)
        #expect(contents == "moving")
    }

    @Test func readMissingFileThrows() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        await #expect(throws: Error.self) {
            _ = try await store.readString(at: root.appendingPathComponent("missing.md"))
        }
    }
}

struct DebouncerTests {
    @Test func burstYieldsSingleBatch() async {
        let debouncer = Debouncer<Int>(quiet: .milliseconds(40))
        await debouncer.submit(1)
        await debouncer.submit(2)
        await debouncer.submit(3)

        var iterator = debouncer.batches.makeAsyncIterator()
        let batch = await iterator.next()
        #expect(batch == [1, 2, 3])
        await debouncer.finish()
    }

    @Test func separatedBurstsYieldSeparateBatches() async {
        let debouncer = Debouncer<String>(quiet: .milliseconds(30))
        await debouncer.submit("a")

        var iterator = debouncer.batches.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == ["a"])

        await debouncer.submit("b")
        await debouncer.submit("c")
        let second = await iterator.next()
        #expect(second == ["b", "c"])
        await debouncer.finish()
    }
}

import Foundation
import Testing
@testable import VaultKit

/// Tests added from the model-tiered coverage audit (pass 46).
struct VaultAuditHardeningTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func unicodeFilenamesRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()
        let url = root.appendingPathComponent("笔记 🚀 möte.md")
        try await store.writeString("unicode name", to: url)
        #expect(try await store.readString(at: url) == "unicode name")
        let listed = VaultEnumerator.snapshot(of: root).map(\.relativePath)
        #expect(listed.contains { $0.contains("🚀") })
    }

    @Test func emptyAndLargeFilesRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultFileStore()

        let empty = root.appendingPathComponent("empty.md")
        try await store.writeString("", to: empty)
        #expect(try await store.readString(at: empty) == "")

        let large = root.appendingPathComponent("large.md")
        let megabyte = String(repeating: "0123456789abcdef", count: 65536)
        try await store.writeString(megabyte, to: large)
        #expect(try await store.readString(at: large) == megabyte)
    }

    @Test func debouncerIgnoresSubmitAfterFinish() async {
        let debouncer = Debouncer<Int>(quiet: .milliseconds(20))
        await debouncer.finish()
        await debouncer.submit(1) // must not crash or emit
        var iterator = debouncer.batches.makeAsyncIterator()
        let value = await iterator.next()
        #expect(value == nil, "finished stream yields nothing")
    }

    @Test func bookmarkToDeletedFolderFailsOrFlagsStale() throws {
        let folder = try makeTempRoot()
        let data = try VaultBookmark.make(for: folder)
        try FileManager.default.removeItem(at: folder)
        do {
            let resolved = try VaultBookmark.resolve(data)
            #expect(resolved.isStale || !FileManager.default.fileExists(atPath: resolved.url.path),
                    "deleted target must surface as stale or missing, never as a silently valid URL")
        } catch {
            // Throwing is equally acceptable — the caller re-prompts.
        }
    }

    #if os(macOS)
        @Test func watcherSeesFilesInNewlyCreatedSubdirectory() async throws {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let watcher = DirectoryWatcher(root: root)
            defer { watcher.stop() }
            try await Task.sleep(for: .milliseconds(100))

            // Structural change: new subdirectory...
            let sub = root.appendingPathComponent("Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(300)) // watch set self-refresh
            // ...then a file inside it must still produce an event.
            try "content".write(to: sub.appendingPathComponent("inner.md"), atomically: true, encoding: .utf8)

            let sawEvent = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await url in watcher.events where url.path.contains("Nested") {
                        return true
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(sawEvent, "watcher must extend to subdirectories created after start")
        }
    #endif
}

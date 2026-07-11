import Foundation
import Testing
@testable import VaultKit

#if os(macOS)
    struct DirectoryWatcherTests {
        @Test func firesWhenFileCreatedInWatchedTree() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WatcherTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let watcher = DirectoryWatcher(root: root)
            defer { watcher.stop() }
            // Give the initial watch set a beat to install.
            try await Task.sleep(for: .milliseconds(100))

            try "hello".write(
                to: root.appendingPathComponent("new.md"),
                atomically: true,
                encoding: .utf8
            )

            let fired = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var iterator = watcher.events.makeAsyncIterator()
                    return await iterator.next() != nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(fired, "expected a directory event within 3s of file creation")
        }
    }
#endif

struct VaultBookmarkTests {
    @Test func bookmarkRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let data = try VaultBookmark.make(for: folder)
        let resolved = try VaultBookmark.resolve(data)
        #expect(resolved.url.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(!resolved.isStale)
    }

    @Test func withAccessRunsBody() {
        let folder = FileManager.default.temporaryDirectory
        let result = VaultBookmark.withAccess(to: folder) { "ran" }
        #expect(result == "ran")
    }
}

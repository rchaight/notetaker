import Foundation
import GRDB
@testable import IndexKit
import Testing

/// `openReadOnly` is what the out-of-process MCP server uses. It must never
/// migrate, never wipe, and never write — the app owns this file.
struct IndexDatabaseReadOnlyTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("index-readonly-\(UUID().uuidString).sqlite").path
    }

    @Test func opensCurrentVersionDatabase() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (writable, _) = try IndexDatabase.open(path: path)
        try writable.queue.write { db in
            try NoteRecord(
                id: "Work/plan.md", title: "plan", folder: "Work",
                modifiedAt: nil, contentHash: "abc"
            ).insert(db)
        }

        let reader = try IndexDatabase.openReadOnly(path: path)
        #expect(try reader.indexedNoteIds() == ["Work/plan.md"])
    }

    @Test func throwsOnSchemaVersionMismatch() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (writable, _) = try IndexDatabase.open(path: path)
        try writable.queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(IndexDatabase.schemaVersion + 99)")
        }

        #expect(throws: IndexDatabase.ReadOnlyOpenError.self) {
            _ = try IndexDatabase.openReadOnly(path: path)
        }
    }

    @Test func throwsOnMissingFileWithoutCreatingIt() throws {
        let path = temporaryPath()
        #expect(throws: (any Error).self) {
            _ = try IndexDatabase.openReadOnly(path: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func neverWritesToTheDatabase() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (writable, _) = try IndexDatabase.open(path: path)
        try writable.queue.write { db in
            try NoteRecord(
                id: "Work/plan.md", title: "plan", folder: "Work",
                modifiedAt: nil, contentHash: "abc"
            ).insert(db)
        }
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date

        let reader = try IndexDatabase.openReadOnly(path: path)
        _ = try reader.indexedNoteIds()
        // A write attempt must be refused by SQLite itself, not merely by
        // convention.
        #expect(throws: (any Error).self) {
            try reader.queue.write { db in
                try db.execute(sql: "DELETE FROM note")
            }
        }
        _ = try reader.indexedNoteIds()

        let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(try reader.indexedNoteIds() == ["Work/plan.md"])
    }
}

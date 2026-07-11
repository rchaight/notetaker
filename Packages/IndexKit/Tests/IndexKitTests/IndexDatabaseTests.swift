import Foundation
import GRDB
@testable import IndexKit
import Testing

struct IndexDatabaseTests {
    @Test func opensAndMigratesInMemory() throws {
        let (db, wiped) = try IndexDatabase.open(path: nil)
        #expect(!wiped)
        let tables = try db.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
        }
        #expect(tables.contains("note"))
        #expect(tables.contains("task"))
        #expect(tables.contains("taskLabel"))
        #expect(tables.contains("outLink"))
        #expect(tables.contains { $0.hasPrefix("noteFTS") })
    }

    @Test func noteAndTaskRoundTrip() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let note = NoteRecord(
            id: "Projects/plan.md", title: "plan", folder: "Projects",
            modifiedAt: nil, contentHash: "abc"
        )
        let task = TaskRecord(
            id: "Projects/plan.md#4", noteId: note.id, line: 4,
            text: "call the dean", rawLine: "- [ ] call the dean >2026-07-15 !p1",
            checked: false, dueDate: "2026-07-15", priority: 1
        )
        try db.queue.write { db in
            try note.insert(db)
            try task.insert(db)
            try TaskLabelRecord(taskId: task.id, label: "admin").insert(db)
            try OutLinkRecord(noteId: note.id, targetTitle: "Budget").insert(db)
        }

        let openTasks = try db.queue.read { db in
            try TaskRecord.filter(Column("checked") == false).fetchAll(db)
        }
        #expect(openTasks == [task])
    }

    @Test func deletingNoteCascadesToTasksAndLinks() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        try db.queue.write { db in
            try NoteRecord(id: "n.md", title: "n", folder: "", modifiedAt: nil, contentHash: "h").insert(db)
            try TaskRecord(id: "n.md#0", noteId: "n.md", line: 0, text: "t",
                           rawLine: "- [ ] t", checked: false).insert(db)
            try OutLinkRecord(noteId: "n.md", targetTitle: "Other").insert(db)
        }
        try db.queue.write { db in
            _ = try NoteRecord.deleteOne(db, key: "n.md")
        }
        let counts = try db.queue.read { db in
            try (
                TaskRecord.fetchCount(db),
                OutLinkRecord.fetchCount(db)
            )
        }
        #expect(counts == (0, 0))
    }

    @Test func fullTextSearchFindsBody() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        try db.updateFullText(noteId: "a.md", title: "Meeting", body: "discussed the accreditation timeline")
        try db.updateFullText(noteId: "b.md", title: "Groceries", body: "milk and eggs")

        #expect(try db.searchNoteIds(matching: "accreditation") == ["a.md"])
        #expect(try db.searchNoteIds(matching: "milk") == ["b.md"])
        // Replacing a note's text replaces its row rather than duplicating.
        try db.updateFullText(noteId: "b.md", title: "Groceries", body: "only bread now")
        #expect(try db.searchNoteIds(matching: "milk").isEmpty)
    }

    @Test func schemaVersionMismatchWipes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.sqlite").path

        let (first, _) = try IndexDatabase.open(path: path)
        try first.queue.write { db in
            try NoteRecord(id: "keep.md", title: "keep", folder: "", modifiedAt: nil, contentHash: "h").insert(db)
            // Simulate an old schema on disk.
            try db.execute(sql: "PRAGMA user_version = 999")
        }

        let (second, wiped) = try IndexDatabase.open(path: path)
        #expect(wiped, "stale schema must trigger a wipe")
        let count = try second.queue.read { db in try NoteRecord.fetchCount(db) }
        #expect(count == 0, "wiped index starts empty, ready for rescan")
    }

    @Test func wipeAllRowsKeepsSchema() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        try db.queue.write { db in
            try NoteRecord(id: "x.md", title: "x", folder: "", modifiedAt: nil, contentHash: "h").insert(db)
        }
        try db.updateFullText(noteId: "x.md", title: "x", body: "searchable")
        try db.wipeAllRows()
        #expect(try db.queue.read { db in try NoteRecord.fetchCount(db) } == 0)
        #expect(try db.searchNoteIds(matching: "searchable").isEmpty)
    }
}

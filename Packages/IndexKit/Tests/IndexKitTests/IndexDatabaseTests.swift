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

struct AuditHardeningDatabaseTests {
    @Test func cascadeIsScopedToTheDeletedNote() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        try db.queue.write { database in
            try NoteRecord(id: "gone.md", title: "gone", folder: "", modifiedAt: nil, contentHash: "a").insert(database)
            try NoteRecord(id: "stays.md", title: "stays", folder: "", modifiedAt: nil, contentHash: "b")
                .insert(database)
            try TaskRecord(id: "gone.md#0", noteId: "gone.md", line: 0, text: "g",
                           rawLine: "- [ ] g", checked: false).insert(database)
            try TaskRecord(id: "stays.md#0", noteId: "stays.md", line: 0, text: "s",
                           rawLine: "- [ ] s", checked: false).insert(database)
        }
        try db.queue.write { database in
            _ = try NoteRecord.deleteOne(database, key: "gone.md")
        }
        let survivors = try db.queue.read { database in
            try TaskRecord.fetchAll(database).map(\.id)
        }
        #expect(survivors == ["stays.md#0"], "cascade must not touch other notes")
    }

    @Test func fileBackedDataSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexReopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.sqlite").path

        let (first, _) = try IndexDatabase.open(path: path)
        let indexer = NoteIndexer(database: first)
        try indexer.index(noteId: "keep.md", contents: "- [ ] survive restart\n", modifiedAt: nil)

        let (second, wiped) = try IndexDatabase.open(path: path)
        #expect(!wiped, "matching schema must not wipe")
        #expect(try second.openTasks().map(\.text) == ["survive restart"])
    }

    @Test func wipeThenRescanRestoresEverything() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "a.md", contents: "- [ ] alpha #tag\nsee [[Beta]]\n", modifiedAt: nil)
        let tasksBefore = try db.openTasks()

        try db.wipeAllRows()
        #expect(try db.openTasks().isEmpty)
        try indexer.rescan(notes: [("a.md", "- [ ] alpha #tag\nsee [[Beta]]\n", nil)])
        #expect(try db.openTasks() == tasksBefore, "the designed recovery path must fully restore")
        #expect(try db.searchNoteIds(matching: "alpha") == ["a.md"], "FTS restored too")
    }
}

struct SemanticChunkTests {
    @Test func chunksRoundTripAndRank() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        try db.queue.write { database in
            try NoteRecord(id: "a.md", title: "a", folder: "", modifiedAt: nil, contentHash: "h").insert(database)
            try NoteRecord(id: "b.md", title: "b", folder: "", modifiedAt: nil, contentHash: "h").insert(database)
        }
        try db.replaceChunks(noteId: "a.md", chunks: [("about dogs", [1, 0, 0]), ("about cats", [0.7, 0.7, 0])])
        try db.replaceChunks(noteId: "b.md", chunks: [("about cars", [0, 0, 1])])

        let results = try db.semanticSearch(query: [1, 0, 0], limit: 5)
        #expect(results.first?.noteId == "a.md")
        #expect(results.count == 2)
        #expect(results[0].score > results[1].score)

        // Replacement really replaces.
        try db.replaceChunks(noteId: "a.md", chunks: [("now about planes", [0, 1, 0])])
        let after = try db.semanticSearch(query: [1, 0, 0], limit: 5)
        #expect(after.first?.noteId == "b.md" || after.first?.score ?? 1 < 0.01)
    }

    @Test func cosineBasics() {
        #expect(IndexDatabase.cosine([1, 0], [1, 0]) == 1)
        #expect(abs(IndexDatabase.cosine([1, 0], [0, 1])) < 0.0001)
        #expect(IndexDatabase.cosine([], []) == 0)
    }

    @Test func deletingNoteDropsItsChunks() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        try db.queue.write { database in
            try NoteRecord(id: "gone.md", title: "g", folder: "", modifiedAt: nil, contentHash: "h").insert(database)
        }
        try db.replaceChunks(noteId: "gone.md", chunks: [("text", [1, 2, 3])])
        try db.queue.write { database in
            _ = try NoteRecord.deleteOne(database, key: "gone.md")
        }
        #expect(try db.semanticSearch(query: [1, 2, 3]).isEmpty)
    }
}

struct BacklinkTests {
    @Test func linkedAndUnlinkedMentionsSplit() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "Budget.md", contents: "# Budget\nnumbers live here\n", modifiedAt: nil)
        try indexer.index(noteId: "plan.md", contents: "See [[Budget]] for numbers\n", modifiedAt: nil)
        try indexer.index(
            noteId: "meeting.md",
            contents: "We discussed the Budget at length without linking\n",
            modifiedAt: nil
        )

        #expect(try db.backlinks(toTitle: "Budget") == ["plan.md"])
        let unlinked = try db.unlinkedMentions(ofTitle: "Budget", excluding: "Budget.md")
        #expect(unlinked.contains("meeting.md"))
        #expect(!unlinked.contains("plan.md"), "linked notes are not 'unlinked mentions'")
        #expect(!unlinked.contains("Budget.md"), "a note never mentions itself")
    }
}

import Foundation
import GRDB
@testable import IndexKit
import Testing

struct NoteIndexerTests {
    private func make() throws -> (IndexDatabase, NoteIndexer) {
        let (db, _) = try IndexDatabase.open(path: nil)
        return (db, NoteIndexer(database: db))
    }

    private let sample = """
    ---
    title: Semester Plan
    ---
    # Plan

    See [[Budget]] for numbers.

    - [ ] email the dean >2026-07-15 !p1 #admin
    - [x] book room
    """

    @Test func indexesTasksLinksAndMetadata() throws {
        let (db, indexer) = try make()
        let changed = try indexer.index(noteId: "Work/plan.md", contents: sample, modifiedAt: nil)
        #expect(changed)

        let (note, tasks, labels, links) = try db.queue.read { db in
            try (
                NoteRecord.fetchOne(db, key: "Work/plan.md"),
                TaskRecord.order(Column("line")).fetchAll(db),
                TaskLabelRecord.fetchAll(db),
                OutLinkRecord.fetchAll(db)
            )
        }
        #expect(note?.title == "plan")
        #expect(note?.folder == "Work")
        #expect(tasks.count == 2)
        #expect(tasks[0].text == "email the dean #admin")
        #expect(tasks[0].dueDate == "2026-07-15")
        #expect(tasks[0].priority == 1)
        #expect(!tasks[0].checked)
        #expect(tasks[1].checked)
        #expect(labels == [TaskLabelRecord(taskId: tasks[0].id, label: "admin")])
        #expect(links == [OutLinkRecord(noteId: "Work/plan.md", targetTitle: "Budget")])
    }

    @Test func unchangedContentIsSkipped() throws {
        let (_, indexer) = try make()
        try indexer.index(noteId: "a.md", contents: sample, modifiedAt: nil)
        let second = try indexer.index(noteId: "a.md", contents: sample, modifiedAt: nil)
        #expect(!second)
    }

    @Test func editReplacesTasksNotDuplicates() throws {
        let (db, indexer) = try make()
        try indexer.index(noteId: "a.md", contents: "- [ ] one\n- [ ] two\n", modifiedAt: nil)
        try indexer.index(noteId: "a.md", contents: "- [x] one\n", modifiedAt: nil)
        let tasks = try db.queue.read { db in try TaskRecord.fetchAll(db) }
        #expect(tasks.count == 1)
        #expect(tasks[0].checked)
    }

    @Test func removeDeletesEverything() throws {
        let (db, indexer) = try make()
        try indexer.index(noteId: "a.md", contents: sample, modifiedAt: nil)
        try indexer.remove(noteId: "a.md")
        let (notes, tasks) = try db.queue.read { db in
            try (NoteRecord.fetchCount(db), TaskRecord.fetchCount(db))
        }
        #expect(notes == 0)
        #expect(tasks == 0)
        #expect(try db.searchNoteIds(matching: "dean").isEmpty)
    }

    @Test func rescanConverges() throws {
        let (db, indexer) = try make()
        try indexer.index(noteId: "stale.md", contents: "- [ ] old\n", modifiedAt: nil)
        try indexer.rescan(notes: [
            ("fresh.md", "- [ ] new task >2026-08-01\n", nil),
            ("other.md", "plain note, no tasks\n", nil),
        ])
        let (notes, tasks) = try db.queue.read { db in
            try (
                NoteRecord.order(Column("id")).fetchAll(db).map(\.id),
                TaskRecord.fetchAll(db)
            )
        }
        #expect(notes == ["fresh.md", "other.md"])
        #expect(tasks.count == 1)
        #expect(tasks[0].dueDate == "2026-08-01")
    }

    @Test func searchSpansTitleAndBody() throws {
        let (db, indexer) = try make()
        try indexer.index(noteId: "Meetings/accreditation.md", contents: "we discussed rubrics\n", modifiedAt: nil)
        #expect(try db.searchNoteIds(matching: "accreditation") == ["Meetings/accreditation.md"])
        #expect(try db.searchNoteIds(matching: "rubrics") == ["Meetings/accreditation.md"])
    }
}

struct SubtaskTests {
    @Test func indentedTasksNestUnderParents() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        let note = """
        - [ ] plan the course
          - [x] outline modules
          - [ ] write syllabus
            - [ ] deep sub-sub task
        - [ ] unrelated top task
        """
        try indexer.index(noteId: "n.md", contents: note, modifiedAt: nil)

        let open = try db.openTasks()
        #expect(open.map(\.text) == ["plan the course", "unrelated top task"],
                "master list shows only top-level tasks")

        let progress = try db.subtaskProgress()
        #expect(progress["n.md#0"]?.done == 1)
        #expect(progress["n.md#0"]?.total == 2, "direct children only")
        #expect(progress["n.md#2"]?.total == 1, "sub-sub nests under the subtask")
    }

    @Test func dedentReturnsToTopLevel() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        let note = "- [ ] parent\n  - [ ] child\n- [ ] sibling\n  - [ ] sibling child\n"
        try indexer.index(noteId: "n.md", contents: note, modifiedAt: nil)
        let progress = try db.subtaskProgress()
        #expect(progress.count == 2, "each parent tracks its own children")
        #expect(try db.openTasks().count == 2)
    }
}

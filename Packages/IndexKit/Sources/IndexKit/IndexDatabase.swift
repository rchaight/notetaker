import Foundation
import GRDB

/// The derived, disposable index. THE invariant: everything in here is
/// rebuildable by re-scanning the vault — losing this file is never data
/// loss. On any schema-version mismatch we simply drop everything and let
/// the caller trigger a full rescan.
public final class IndexDatabase: Sendable {
    /// Bump when the schema changes; mismatch wipes and rebuilds.
    public static let schemaVersion = 3

    public let queue: DatabaseQueue

    /// - Parameter path: file path, or nil for in-memory (tests).
    /// - Returns: `wiped` true when a stale schema was dropped — the caller
    ///   must rescan the vault.
    public static func open(path: String?) throws -> (database: IndexDatabase, wiped: Bool) {
        let queue: DatabaseQueue = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()

        let storedVersion = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        var wiped = false
        if storedVersion != 0, storedVersion != schemaVersion {
            try queue.write { db in
                for table in try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
                ) {
                    try db.execute(sql: "DROP TABLE IF EXISTS \(table.quotedDatabaseIdentifier)")
                }
                try db.execute(sql: "PRAGMA user_version = 0")
            }
            wiped = true
        }

        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
        }
        return (IndexDatabase(queue: queue), wiped)
    }

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: NoteRecord.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("folder", .text).notNull().indexed()
                t.column("modifiedAt", .datetime)
                t.column("contentHash", .text).notNull()
            }
            try db.create(table: TaskRecord.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("noteId", .text).notNull().indexed()
                    .references(NoteRecord.databaseTableName, onDelete: .cascade)
                t.column("line", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("rawLine", .text).notNull()
                t.column("checked", .boolean).notNull().indexed()
                t.column("dueDate", .text).indexed()
                t.column("startDate", .text)
                t.column("priority", .integer)
                t.column("recurrence", .text)
            }
            try db.create(table: TaskLabelRecord.databaseTableName) { t in
                t.column("taskId", .text).notNull().indexed()
                    .references(TaskRecord.databaseTableName, onDelete: .cascade)
                t.column("label", .text).notNull().indexed()
                t.primaryKey(["taskId", "label"])
            }
            try db.create(table: OutLinkRecord.databaseTableName) { t in
                t.column("noteId", .text).notNull().indexed()
                    .references(NoteRecord.databaseTableName, onDelete: .cascade)
                t.column("targetTitle", .text).notNull().indexed()
                t.primaryKey(["noteId", "targetTitle"])
            }
            // Full text over note title + body; body lives only here (the
            // file is the source, this is just the search index).
            try db.create(virtualTable: "noteFTS", using: FTS5()) { t in
                t.column("noteId").notIndexed()
                t.column("title")
                t.column("body")
            }
        }
        return migrator
    }
}

public extension IndexDatabase {
    /// Replace a note's full-text row (delete + insert keyed by noteId).
    func updateFullText(noteId: String, title: String, body: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM noteFTS WHERE noteId = ?", arguments: [noteId])
            try db.execute(
                sql: "INSERT INTO noteFTS (noteId, title, body) VALUES (?, ?, ?)",
                arguments: [noteId, title, body]
            )
        }
    }

    /// BM25-ranked note ids matching an FTS5 query string.
    func searchNoteIds(matching query: String, limit: Int = 50) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT noteId FROM noteFTS WHERE noteFTS MATCH ?
                ORDER BY bm25(noteFTS) LIMIT ?
                """,
                arguments: [query, limit]
            )
        }
    }

    /// All unchecked tasks, ordered for the master list: priority first
    /// (nulls last), then due date (nulls last), then stable note/line order.
    func openTasks() throws -> [TaskRecord] {
        try queue.read { db in
            try TaskRecord
                .filter(Column("checked") == false)
                .order(
                    Column("priority").ascNullsLast,
                    Column("dueDate").ascNullsLast,
                    Column("noteId"),
                    Column("line")
                )
                .fetchAll(db)
        }
    }

    func indexedNoteIds() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note")
        }
    }

    /// Wipes every row (schema intact) — the "delete index, re-scan" path.
    func wipeAllRows() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM \(TaskLabelRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM \(OutLinkRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM \(TaskRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM \(NoteRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM noteFTS")
        }
    }
}

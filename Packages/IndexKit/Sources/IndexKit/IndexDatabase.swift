import Foundation
import GRDB

/// The derived, disposable index. THE invariant: everything in here is
/// rebuildable by re-scanning the vault — losing this file is never data
/// loss. On any schema-version mismatch we simply drop everything and let
/// the caller trigger a full rescan.
public final class IndexDatabase: Sendable {
    /// Bump when the schema changes; mismatch wipes and rebuilds.
    public static let schemaVersion = 13

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
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("bookmarked", .boolean).notNull().defaults(to: false)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("isProject", .boolean).notNull().defaults(to: false)
                t.column("projectStatus", .text)
                t.column("projectStart", .text)
                t.column("projectDue", .text)
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
                t.column("parentId", .text).indexed()
                t.column("blockId", .text)
                t.column("dependsOn", .text)
                t.column("completedDay", .text).indexed()
                t.column("assignee", .text)
            }
            try db.create(table: TaskLabelRecord.databaseTableName) { t in
                t.column("taskId", .text).notNull().indexed()
                    .references(TaskRecord.databaseTableName, onDelete: .cascade)
                t.column("label", .text).notNull().indexed()
                t.primaryKey(["taskId", "label"])
            }
            try db.create(table: NoteTagRecord.databaseTableName) { t in
                t.column("noteId", .text).notNull().indexed()
                    .references(NoteRecord.databaseTableName, onDelete: .cascade)
                t.column("tag", .text).notNull().indexed()
                t.primaryKey(["noteId", "tag"])
            }
            try db.create(table: OutLinkRecord.databaseTableName) { t in
                t.column("noteId", .text).notNull().indexed()
                    .references(NoteRecord.databaseTableName, onDelete: .cascade)
                t.column("targetTitle", .text).notNull().indexed()
                t.primaryKey(["noteId", "targetTitle"])
            }
            try db.create(table: "noteChunk") { t in
                t.column("noteId", .text).notNull().indexed()
                    .references(NoteRecord.databaseTableName, onDelete: .cascade)
                t.column("chunkIndex", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("embedding", .blob).notNull()
                t.primaryKey(["noteId", "chunkIndex"])
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

    /// All unchecked TOP-LEVEL tasks, ordered for the master list: priority
    /// first (nulls last), then due date (nulls last), then note/line order.
    /// Subtasks surface as their parent's progress, not as separate rows.
    func openTasks() throws -> [TaskRecord] {
        try queue.read { db in
            try TaskRecord
                .filter(Column("checked") == false)
                .filter(Column("parentId") == nil)
                .order(
                    Column("priority").ascNullsLast,
                    Column("dueDate").ascNullsLast,
                    Column("noteId"),
                    Column("line")
                )
                .fetchAll(db)
        }
    }

    /// parent taskId → (done, total) across its direct subtasks.
    func subtaskProgress() throws -> [String: (done: Int, total: Int)] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT parentId, SUM(checked) AS done, COUNT(*) AS total
            FROM task WHERE parentId IS NOT NULL GROUP BY parentId
            """)
            var progress: [String: (done: Int, total: Int)] = [:]
            for row in rows {
                if let parent: String = row["parentId"] {
                    progress[parent] = (row["done"] ?? 0, row["total"] ?? 0)
                }
            }
            return progress
        }
    }

    /// Notes whose [[wikilinks]] point at this title (linked backlinks).
    func backlinks(toTitle title: String) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT noteId FROM outLink WHERE targetTitle = ? COLLATE NOCASE ORDER BY noteId",
                arguments: [title]
            )
        }
    }

    /// Notes mentioning the title as text without linking it — FTS phrase
    /// match minus linked backlinks minus the note itself.
    func unlinkedMentions(ofTitle title: String, excluding noteId: String) throws -> [String] {
        let phrase = "\"" + title.replacingOccurrences(of: "\"", with: "") + "\""
        let mentions = try searchNoteIds(matching: phrase, limit: 25)
        let linked = try Set(backlinks(toTitle: title))
        return mentions.filter { $0 != noteId && !linked.contains($0) }
    }

    /// taskId → its labels, for filter evaluation.
    func labelsByTaskId() throws -> [String: [String]] {
        try queue.read { db in
            let rows = try TaskLabelRecord.fetchAll(db)
            return Dictionary(grouping: rows, by: \.taskId).mapValues { $0.map(\.label) }
        }
    }

    func indexedNoteIds() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note")
        }
    }

    /// Replaces a note's semantic chunks (embeddings as float32 blobs).
    func replaceChunks(noteId: String, chunks: [(text: String, embedding: [Float])]) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM noteChunk WHERE noteId = ?", arguments: [noteId])
            for (index, chunk) in chunks.enumerated() {
                let blob = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
                try db.execute(
                    sql: "INSERT INTO noteChunk (noteId, chunkIndex, text, embedding) VALUES (?, ?, ?, ?)",
                    arguments: [noteId, index, chunk.text, blob]
                )
            }
        }
    }

    /// Brute-force cosine over all chunks — plenty for a personal vault.
    /// Returns noteIds ranked by their best-matching chunk.
    func semanticSearch(query: [Float], limit: Int = 10) throws -> [(noteId: String, score: Float)] {
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT noteId, embedding FROM noteChunk")
        }
        var best: [String: Float] = [:]
        for row in rows {
            guard let noteId: String = row["noteId"], let blob: Data = row["embedding"] else { continue }
            let vector: [Float] = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard vector.count == query.count else { continue }
            let score = Self.cosine(vector, query)
            if score > (best[noteId] ?? -1) {
                best[noteId] = score
            }
        }
        return best.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in 0 ..< min(a.count, b.count) {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        let denominator = (na.squareRoot() * nb.squareRoot())
        return denominator > 0 ? dot / denominator : 0
    }

    /// Wipes every row (schema intact) — the "delete index, re-scan" path.
    func projects() throws -> [NoteRecord] {
        try queue.read { db in
            try NoteRecord.filter(Column("isProject") == true)
                .order(Column("projectDue").ascNullsLast, Column("title"))
                .fetchAll(db)
        }
    }

    /// Checked/total inline todos per note — drives auto-% complete.
    func noteTaskProgress() throws -> [String: (done: Int, total: Int)] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT noteId, SUM(checked) AS done, COUNT(*) AS total
            FROM task GROUP BY noteId
            """)
            var progress: [String: (done: Int, total: Int)] = [:]
            for row in rows {
                progress[row["noteId"]] = (row["done"] as Int, row["total"] as Int)
            }
            return progress
        }
    }

    /// Every task (open and done, all nesting levels) in one note, in file
    /// order — the project detail view shows the full picture.
    func tasks(inNote noteId: String) throws -> [TaskRecord] {
        try queue.read { db in
            try TaskRecord.filter(Column("noteId") == noteId)
                .order(Column("line"))
                .fetchAll(db)
        }
    }

    func favoriteNoteIds() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note WHERE favorite ORDER BY title")
        }
    }

    /// Completed tasks with a logged day, newest day first (Logbook).
    func completedTasks(limit: Int = 500) throws -> [TaskRecord] {
        try queue.read { db in
            try TaskRecord
                .filter(Column("checked") == true)
                .filter(Column("completedDay") != nil)
                .order(Column("completedDay").desc, Column("noteId"), Column("line"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Every wikilink edge in the vault: (source noteId, target TITLE).
    func allOutLinks() throws -> [(from: String, toTitle: String)] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT noteId, targetTitle FROM outLink").map {
                ($0["noteId"] as String, $0["targetTitle"] as String)
            }
        }
    }

    func pinnedNoteIds() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note WHERE pinned ORDER BY title")
        }
    }

    func bookmarkedNoteIds() throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note WHERE bookmarked ORDER BY title")
        }
    }

    /// Every distinct note tag with how many notes carry it. Nested tags
    /// ("project/alpha") count toward themselves only; the UI aggregates
    /// ancestors from the components.
    func tagsWithCounts() throws -> [(tag: String, count: Int)] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
            SELECT tag, COUNT(DISTINCT noteId) AS notes
            FROM noteTag GROUP BY tag ORDER BY tag
            """).map { ($0["tag"] as String, $0["notes"] as Int) }
        }
    }

    /// Notes carrying `tag` or any nested tag under it ("project" matches
    /// "project" and "project/alpha").
    func noteIds(withTag tag: String) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: """
            SELECT DISTINCT noteId FROM noteTag
            WHERE tag = ?1 OR tag LIKE ?1 || '/%'
            ORDER BY noteId
            """, arguments: [tag])
        }
    }

    func wipeAllRows() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM \(TaskLabelRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM \(NoteTagRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM \(OutLinkRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM \(TaskRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM \(NoteRecord.databaseTableName)")
            try db.execute(sql: "DELETE FROM noteChunk")
            try db.execute(sql: "DELETE FROM noteFTS")
        }
    }
}

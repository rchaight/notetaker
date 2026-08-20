import Foundation
import GRDB

/// Read-only queries for the `_index.md` generation driver (App target's
/// `VaultIndexService`). Kept out of IndexDatabase.swift itself — a
/// concurrently owned file — but the driver only needs plain Swift return
/// types here, so it never has to `import GRDB`.
public extension IndexDatabase {
    /// Every indexed note — the raw material for the vault-wide table of
    /// contents. The driver groups these by `folder`.
    func allNoteRecords() throws -> [NoteRecord] {
        try queue.read { db in try NoteRecord.fetchAll(db) }
    }

    /// Open (unchecked) task count per note, all nesting levels — the
    /// `_index.md` line's "N open tasks" segment.
    func openTaskCountsByNoteId() throws -> [String: Int] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT noteId, COUNT(*) AS n FROM task WHERE checked = 0 GROUP BY noteId
            """)
            var counts: [String: Int] = [:]
            for row in rows {
                counts[row["noteId"] as String] = row["n"] as Int
            }
            return counts
        }
    }

    /// Topic tags per note — the `_index.md` line's "#tags" segment.
    func tagsByNoteId() throws -> [String: [String]] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT noteId, tag FROM noteTag ORDER BY noteId, tag")
            var tags: [String: [String]] = [:]
            for row in rows {
                tags[row["noteId"] as String, default: []].append(row["tag"] as String)
            }
            return tags
        }
    }
}

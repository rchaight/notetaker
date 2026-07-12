import CryptoKit
import Foundation
import GRDB
import MarkdownKit
import TaskEngine

/// Inbound sync: note contents → index rows. One transaction per note;
/// unchanged contents (SHA-256) are skipped so vault-wide rescans stay
/// cheap. Everything written here is derivable from the file — the file is
/// truth, these rows are cache.
public struct NoteIndexer: Sendable {
    private let database: IndexDatabase

    public init(database: IndexDatabase) {
        self.database = database
    }

    /// Indexes one note. Returns false when the stored hash already matches
    /// (nothing to do).
    @discardableResult
    public func index(
        noteId: String,
        contents: String,
        modifiedAt: Date?,
        today: Date = Date()
    ) throws -> Bool {
        let hash = Self.hash(contents)
        let existing = try database.queue.read { db in
            try NoteRecord.fetchOne(db, key: noteId)
        }
        if existing?.contentHash == hash {
            return false
        }

        let document = MarkdownDocument(source: contents)
        let title = URL(fileURLWithPath: noteId).deletingPathExtension().lastPathComponent
        let folder = noteId.split(separator: "/").dropLast().joined(separator: "/")
        let note = NoteRecord(
            id: noteId, title: title, folder: folder,
            modifiedAt: modifiedAt, contentHash: hash
        )

        // Line numbers must be in FILE coordinates (outbound writes edit the
        // file), so scan the full contents, not just the body.
        let scanned = NoteScanner.tasks(in: contents)
        let links = NoteScanner.wikilinkTargets(in: document.body)

        try database.queue.write { db in
            try note.save(db)
            try TaskRecord.filter(Column("noteId") == noteId).deleteAll(db)
            try OutLinkRecord.filter(Column("noteId") == noteId).deleteAll(db)
            // (indent, taskId) stack of enclosing tasks for subtask nesting.
            var enclosing: [(indent: Int, id: String)] = []
            for task in scanned {
                let parsed = TaskTokenParser.parse(task.text, today: today)
                while let last = enclosing.last, last.indent >= task.indent {
                    enclosing.removeLast()
                }
                let parentId = enclosing.last?.id
                let record = TaskRecord(
                    id: "\(noteId)#\(task.line)",
                    noteId: noteId,
                    line: task.line,
                    text: parsed.cleanText,
                    rawLine: task.rawLine,
                    checked: task.checked,
                    dueDate: parsed.dueDate,
                    startDate: parsed.startDate,
                    priority: parsed.priority,
                    recurrence: parsed.recurrence?.rawToken,
                    parentId: parentId
                )
                enclosing.append((task.indent, record.id))
                try record.save(db)
                for label in parsed.labels {
                    try TaskLabelRecord(taskId: record.id, label: label).save(db)
                }
            }
            for target in links {
                try OutLinkRecord(noteId: noteId, targetTitle: target).save(db)
            }
        }
        try database.updateFullText(noteId: noteId, title: title, body: document.body)
        return true
    }

    public func remove(noteId: String) throws {
        _ = try database.queue.write { db in
            try NoteRecord.deleteOne(db, key: noteId)
        }
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM noteFTS WHERE noteId = ?", arguments: [noteId])
        }
    }

    /// Full rebuild: wipe rows, index everything. The recovery path for
    /// schema wipes and the "delete index, re-scan converges" guarantee.
    public func rescan(notes: [(id: String, contents: String, modifiedAt: Date?)]) throws {
        try database.wipeAllRows()
        for note in notes {
            try index(noteId: note.id, contents: note.contents, modifiedAt: note.modifiedAt)
        }
    }

    static func hash(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

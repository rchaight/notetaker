import Foundation
import GRDB

/// One indexed note file. `id` is the vault-relative path — stable across
/// devices because the vault structure IS the source of truth.
public struct NoteRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note"

    public var id: String
    public var title: String
    public var folder: String
    public var modifiedAt: Date?
    public var contentHash: String

    public init(id: String, title: String, folder: String, modifiedAt: Date?, contentHash: String) {
        self.id = id
        self.title = title
        self.folder = folder
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
    }
}

/// One inline todo extracted from a note line. Rebuildable: every field
/// derives from the file; `line` anchors outbound writes.
public struct TaskRecord: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task"

    public var id: String // "<noteId>#<line>" until durable ^ids (M3.2)
    public var noteId: String
    public var line: Int
    public var text: String
    public var rawLine: String
    public var checked: Bool
    public var dueDate: String? // ISO yyyy-MM-dd; TaskEngine owns semantics
    public var priority: Int? // 1 (highest) … 4, nil = none
    /// Raw recurrence token ("&every 3 days"); nil = one-shot task.
    public var recurrence: String?

    public init(
        id: String, noteId: String, line: Int, text: String, rawLine: String,
        checked: Bool, dueDate: String? = nil, priority: Int? = nil, recurrence: String? = nil
    ) {
        self.id = id
        self.noteId = noteId
        self.line = line
        self.text = text
        self.rawLine = rawLine
        self.checked = checked
        self.dueDate = dueDate
        self.priority = priority
        self.recurrence = recurrence
    }
}

/// A #tag or @label attached to a task.
public struct TaskLabelRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "taskLabel"

    public var taskId: String
    public var label: String

    public init(taskId: String, label: String) {
        self.taskId = taskId
        self.label = label
    }
}

/// A [[wikilink]] from one note to a target title (backlinks = reverse query).
public struct OutLinkRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "outLink"

    public var noteId: String
    public var targetTitle: String

    public init(noteId: String, targetTitle: String) {
        self.noteId = noteId
        self.targetTitle = targetTitle
    }
}

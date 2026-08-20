import Foundation
import IndexKit
import MarkdownKit
import MCP
import TaskEngine

public extension VaultService {
    /// Filters for the `tasks` tool. All optional — no filter means every
    /// open task in the vault.
    struct TaskQuery: Sendable {
        public var dueWithinDays: Int?
        public var assignee: String?
        public var kind: String?
        public var label: String?
        public var includeCompleted: Bool
        public var limit: Int

        public init(
            dueWithinDays: Int? = nil, assignee: String? = nil, kind: String? = nil,
            label: String? = nil, includeCompleted: Bool = false, limit: Int = 100
        ) {
            self.dueWithinDays = dueWithinDays
            self.assignee = assignee
            self.kind = kind
            self.label = label
            self.includeCompleted = includeCompleted
            self.limit = limit
        }
    }

    /// One flat, filtered task list drawn from the index — or, when the
    /// index can't answer, re-derived from the markdown with the same
    /// `TaskTokenParser` every other surface uses.
    func tasks(_ query: TaskQuery, today: Date = Date()) -> Value {
        let indexed = withIndex { database -> [TaskEntry] in
            let labels = (try? database.labelsByTaskId()) ?? [:]
            return try database.allTasks(includingCompleted: query.includeCompleted).map { record in
                TaskEntry(
                    text: record.text, checked: record.checked, due: record.dueDate,
                    start: record.startDate, priority: record.priority,
                    recurrence: record.recurrence, tags: labels[record.id] ?? [],
                    assignee: record.assignee, kind: record.kind,
                    path: record.noteId, line: record.line
                )
            }
        }

        let entries = (indexed ?? scanTasks(query.includeCompleted, today: today))
            .filter { matches(query: query, today: today, entry: $0) }
            .sorted(by: TaskEntry.masterListOrder)
        return .object([
            "source": .string(indexed == nil ? "scan" : "index"),
            "count": .int(min(entries.count, query.limit)),
            "tasks": .array(entries.prefix(query.limit).map(\.value)),
        ])
    }

    private func scanTasks(_ includeCompleted: Bool, today: Date) -> [TaskEntry] {
        var entries: [TaskEntry] = []
        for file in VaultFiles.markdownFiles(in: location.root) {
            guard let contents = VaultFiles.quickRead(file.url) else { continue }
            // Locked notes hold ciphertext; there are no tasks to find and
            // scanning them would only produce garbage.
            guard !NoteReader.note(from: contents, relativePath: file.relativePath).locked else { continue }
            for scanned in NoteScanner.tasks(in: contents) {
                if scanned.checked, !includeCompleted {
                    continue
                }
                let parsed = TaskTokenParser.parse(scanned.text, today: today)
                entries.append(TaskEntry(
                    text: parsed.cleanText, checked: scanned.checked, due: parsed.dueDate,
                    start: parsed.startDate, priority: parsed.priority,
                    recurrence: parsed.recurrence?.rawToken, tags: parsed.labels,
                    assignee: parsed.assignee, kind: parsed.kind,
                    path: file.relativePath, line: scanned.line
                ))
            }
        }
        return entries
    }

    private func matches(query: TaskQuery, today: Date, entry: TaskEntry) -> Bool {
        if let wanted = query.assignee, entry.assignee?.caseInsensitiveCompare(wanted) != .orderedSame {
            return false
        }
        if let wanted = query.kind, entry.kind?.caseInsensitiveCompare(wanted) != .orderedSame {
            return false
        }
        if let wanted = query.label,
           !entry.tags.contains(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return false
        }
        if let days = query.dueWithinDays {
            // Overdue counts as due — "what's on my plate" is the question.
            guard let due = entry.due,
                  let horizon = Calendar.current.date(byAdding: .day, value: days, to: today)
            else { return false }
            return due <= VaultService.day.string(from: horizon)
        }
        return true
    }
}

/// One task as the MCP server reports it, from either the index or a scan.
struct TaskEntry: Sendable {
    let text: String
    let checked: Bool
    let due: String?
    let start: String?
    let priority: Int?
    let recurrence: String?
    let tags: [String]
    let assignee: String?
    let kind: String?
    let path: String
    let line: Int

    /// The same ordering the app's master list uses: priority, then due
    /// date, nulls last, then file order.
    static func masterListOrder(_ lhs: TaskEntry, _ rhs: TaskEntry) -> Bool {
        if lhs.priority != rhs.priority {
            return (lhs.priority ?? .max) < (rhs.priority ?? .max)
        }
        if lhs.due != rhs.due {
            return (lhs.due ?? "9999-99-99") < (rhs.due ?? "9999-99-99")
        }
        return (lhs.path, lhs.line) < (rhs.path, rhs.line)
    }

    var value: Value {
        var payload: [String: Value] = [
            "text": .string(text),
            "checked": .bool(checked),
            "path": .string(path),
            "line": .int(line),
        ]
        if let due {
            payload["due"] = .string(due)
        }
        if let start {
            payload["start"] = .string(start)
        }
        if let priority {
            payload["priority"] = .int(priority)
        }
        if let recurrence {
            payload["recurrence"] = .string(recurrence)
        }
        if let assignee {
            payload["assignee"] = .string(assignee)
        }
        if let kind {
            payload["kind"] = .string(kind)
        }
        if !tags.isEmpty {
            payload["tags"] = .array(tags.map { .string($0) })
        }
        return .object(payload)
    }
}

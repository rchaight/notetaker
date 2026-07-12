import Foundation
import GRDB
@testable import IndexKit
import MarkdownKit
import TaskEngine
import Testing

/// Cross-module integration: MarkdownKit scanning, TaskEngine semantics,
/// and IndexKit storage working as one pipeline — the flows the app
/// actually runs, end to end, including repeat-round stability.
struct PipelineIntegrationTests {
    private var today: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 12; components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let note = """
    ---
    title: Integration
    ---
    # Plan for [[Budget]]

    - [ ] email dean >2026-07-15 !p1 #admin
    - [ ] water plants >2026-07-10 &every 3 days
    - [ ] draft report ~2026-07-20 >2026-07-24
    - [x] book room
    """

    @Test func fullTaskLifecycleAcrossModules() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "plan.md", contents: note, modifiedAt: nil, today: today)

        // Index sees the right shape.
        var open = try db.openTasks()
        #expect(open.count == 3)
        #expect(open[0].priority == 1)
        #expect(open.contains { $0.recurrence == "&every 3 days" })
        #expect(open.contains { $0.startDate == "2026-07-20" })

        // Filter grammar agrees with indexed fields.
        let labels = try db.labelsByTaskId()
        let filter = TaskFilter.parse("p1 #admin")
        let matching = open.filter {
            filter.matches(text: $0.text, noteId: $0.noteId, dueDate: $0.dueDate,
                           priority: $0.priority, labels: labels[$0.id] ?? [],
                           today: today, calendar: calendar)
        }
        #expect(matching.map(\.text) == ["email dean #admin"])

        // Toggle the non-recurring task via the outbound path, reindex, verify.
        let target = matching[0]
        let toggled = TaskLineToggler.toggle(
            contents: note, anchorLine: target.line, expectedRawLine: target.rawLine
        )
        #expect(toggled?.nowChecked == true)
        try indexer.index(noteId: "plan.md", contents: #require(toggled?.contents), modifiedAt: nil, today: today)
        open = try db.openTasks()
        #expect(!open.contains { $0.id == target.id }, "completed task leaves the open list")

        // Complete the recurring task: date advances, stays open, still indexed open.
        let recurring = try #require(open.first { $0.recurrence != nil })
        let completedLine = try #require(RecurrenceEngine.completeTaskLine(
            recurring.rawLine, today: today, calendar: calendar
        ))
        #expect(completedLine.contains("- [ ]"), "recurring completion keeps the box open")
        #expect(completedLine.contains(">2026-07-13"), "overdue series catches up past today")
        let rewritten = try TaskLineToggler.replacingLine(
            #require(toggled?.contents), at: recurring.line, with: completedLine
        )
        try indexer.index(noteId: "plan.md", contents: rewritten, modifiedAt: nil, today: today)
        let after = try db.openTasks().first { $0.recurrence != nil }
        #expect(after?.dueDate == "2026-07-13")

        // Wipe + rescan converges to the same state (files are truth).
        let before = try db.openTasks()
        try indexer.rescan(notes: [("plan.md", rewritten, nil)])
        #expect(try db.openTasks() == before)
    }

    @Test func editorAndMasterListCompletionAgree() {
        let text = "- [ ] water plants >2026-07-10 &every 3 days\n"
        // Editor path: token-range based.
        let tokenRange = (text as NSString).range(of: "[ ]")
        let viaEditor = RecurrenceEngine.completeTask(
            in: text, tokenRange: tokenRange, today: today, calendar: calendar
        )
        // Master-list path: line based.
        let viaList = RecurrenceEngine.completeTaskLine(
            "- [ ] water plants >2026-07-10 &every 3 days", today: today, calendar: calendar
        ).map { $0 + "\n" }
        #expect(viaEditor == viaList, "every surface must complete tasks identically")
    }

    @Test func repeatedIndexingIsIdempotentAndStable() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "a.md", contents: note, modifiedAt: nil, today: today)
        let baseline = try db.openTasks()

        for round in 1 ... 5 {
            let changed = try indexer.index(noteId: "a.md", contents: note, modifiedAt: nil, today: today)
            #expect(!changed, "round \(round): unchanged content must be skipped")
            #expect(try db.openTasks() == baseline, "round \(round): rows must not drift")
        }
    }

    @Test func quickAddOutputRoundTripsThroughIndex() throws {
        let result = try #require(QuickAddParser.parse(
            "review grant >2026-07-20 !p2 #research", today: today, calendar: calendar
        ))
        let contents = "# Inbox\n\n" + result.markdownLine + "\n"
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "Inbox.md", contents: contents, modifiedAt: nil, today: today)

        let tasks = try db.openTasks()
        #expect(tasks.count == 1)
        #expect(tasks[0].dueDate == result.metadata.dueDate)
        #expect(tasks[0].priority == result.metadata.priority)
        let labels = try db.labelsByTaskId()
        #expect(labels[tasks[0].id] == ["research"], "quick-added labels survive the round trip")
    }
}

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
        let toggledLine = try #require(TaskLineToggler.locate(
            contents: note, anchorLine: target.line, expectedRawLine: target.rawLine
        ))
        let toggledLineText = try #require(RecurrenceEngine.completeTaskLine(
            target.rawLine, today: today, calendar: calendar
        ))
        #expect(toggledLineText.contains("- [x]"))
        #expect(toggledLineText.hasSuffix(" ✅2026-07-12"), "completion stamps the Logbook day")
        let toggled = TaskLineToggler.replacingLine(note, at: toggledLine, with: toggledLineText)
        try indexer.index(noteId: "plan.md", contents: toggled, modifiedAt: nil, today: today)
        open = try db.openTasks()
        #expect(!open.contains { $0.id == target.id }, "completed task leaves the open list")
        #expect(try db.completedTasks().contains { $0.id == target.id && $0.completedDay == "2026-07-12" })

        // Complete the recurring task: date advances, stays open, still indexed open.
        let recurring = try #require(open.first { $0.recurrence != nil })
        let completedLine = try #require(RecurrenceEngine.completeTaskLine(
            recurring.rawLine, today: today, calendar: calendar
        ))
        #expect(completedLine.contains("- [ ]"), "recurring completion keeps the box open")
        #expect(completedLine.contains(">2026-07-13"), "overdue series catches up past today")
        let rewritten = TaskLineToggler.replacingLine(toggled, at: recurring.line, with: completedLine)
        try indexer.index(noteId: "plan.md", contents: rewritten, modifiedAt: nil, today: today)
        let after = try db.openTasks().first { $0.recurrence != nil }
        #expect(after?.dueDate == "2026-07-13")

        // Wipe + rescan converges to the same state (files are truth).
        let before = try db.openTasks()
        try indexer.rescan(notes: [("plan.md", rewritten, nil)])
        #expect(try db.openTasks() == before)
    }

    @Test func renameCandidatesComeFromBacklinksAndRewriteConverges() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        let files: [String: String] = [
            "Plan.md": "# Plan\n\n## Budget\n\nNumbers.\n",
            "a.md": "---\ntitle: A\n---\nSee [[Plan]] first.\n",
            "b.md": "Aliased [[Plan|the plan]] and [[Plan#Budget]].\n",
            "Work/c.md": "Pathed [[Projects/Plan#Budget|numbers]] and ![[Plan]].\n",
            "d.md": "Unrelated [[Plans]] and `[[Plan]]` in code.\n",
        ]
        for (id, contents) in files {
            try indexer.index(noteId: id, contents: contents, modifiedAt: nil)
        }

        // The index only nominates candidates...
        let candidates = try db.backlinks(toTitle: "Plan")
        #expect(candidates == ["Work/c.md", "a.md", "b.md"])

        // ...the files decide: rewrite each candidate's body, then reindex it.
        var rewritten = files
        var changedLinks = 0
        for id in candidates {
            let document = try MarkdownDocument(source: #require(files[id]))
            let result = WikilinkSyntax.rewrite(
                document.body, renamingTitle: "Plan", to: "Plan 2026",
                excluding: MarkdownStyler.codeRanges(in: document.body)
            )
            #expect(result.count > 0, "\(id) was nominated, so it must contain a real link")
            changedLinks += result.count
            let updated = MarkdownDocument(frontmatter: document.frontmatter, body: result.text).render()
            rewritten[id] = updated
            try indexer.index(noteId: id, contents: updated, modifiedAt: nil)
        }
        #expect(changedLinks == 5)
        #expect(rewritten["a.md"] == "---\ntitle: A\n---\nSee [[Plan 2026]] first.\n")
        #expect(rewritten["b.md"] == "Aliased [[Plan 2026|the plan]] and [[Plan 2026#Budget]].\n")
        #expect(rewritten["Work/c.md"] == "Pathed [[Projects/Plan 2026#Budget|numbers]] and ![[Plan 2026]].\n")
        #expect(rewritten["d.md"] == files["d.md"], "never nominated, never touched")

        #expect(try db.backlinks(toTitle: "Plan").isEmpty)
        #expect(try db.backlinks(toTitle: "Plan 2026") == ["Work/c.md", "a.md", "b.md"])
        #expect(try db.backlinks(toTitle: "Plans") == ["d.md"])

        // A rescan from the rewritten files converges to the same index.
        try indexer.rescan(notes: rewritten.map { (id: $0.key, contents: $0.value, modifiedAt: nil) })
        #expect(try db.backlinks(toTitle: "Plan").isEmpty)
        #expect(try db.backlinks(toTitle: "Plan 2026") == ["Work/c.md", "a.md", "b.md"])
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

        // Non-recurring: both paths stamp ✅ identically, and unchecking
        // (either path) strips it again.
        let once = "- [ ] email dean >2026-07-15 !p1 #admin\n"
        let onceBox = (once as NSString).range(of: "[ ]")
        let onceViaEditor = RecurrenceEngine.completeTask(
            in: once, tokenRange: onceBox, today: today, calendar: calendar
        )
        let onceViaList = RecurrenceEngine.completeTaskLine(
            "- [ ] email dean >2026-07-15 !p1 #admin", today: today, calendar: calendar
        ).map { $0 + "\n" }
        #expect(onceViaEditor == onceViaList)
        #expect(onceViaEditor == "- [x] email dean >2026-07-15 !p1 #admin ✅2026-07-12\n")
        let reopened = RecurrenceEngine.completeTask(
            in: onceViaEditor ?? "", tokenRange: onceBox, today: today, calendar: calendar
        )
        #expect(reopened == once, "unchecking restores the original bytes")
    }

    /// The editor edits its buffer, the autosave writes the file, the index
    /// re-reads it: a check-off must land in the Logbook with today's day,
    /// and unchecking must take it out again (spec 02).
    @Test func editorCompletionAppearsInLogbook() throws {
        let text = "# Inbox\n\n- [ ] ship the thing >2026-07-15\n- [ ] other\n"
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "Inbox.md", contents: text, modifiedAt: nil, today: today)
        #expect(try db.completedTasks().isEmpty)

        let firstBox = (text as NSString).range(of: "[ ]")
        let checked = try #require(RecurrenceEngine.completeTask(
            in: text, tokenRange: firstBox, today: today, calendar: calendar
        ))
        try indexer.index(noteId: "Inbox.md", contents: checked, modifiedAt: nil, today: today)
        let logbook = try db.completedTasks()
        #expect(logbook.map(\.text) == ["ship the thing"])
        #expect(logbook.first?.completedDay == "2026-07-12")
        #expect(try db.openTasks().map(\.text) == ["other"])

        let unchecked = try #require(RecurrenceEngine.completeTask(
            in: checked, tokenRange: firstBox, today: today, calendar: calendar
        ))
        #expect(unchecked == text, "unchecking removes the stamp from the file")
        try indexer.index(noteId: "Inbox.md", contents: unchecked, modifiedAt: nil, today: today)
        #expect(try db.completedTasks().isEmpty)
        #expect(try db.openTasks().count == 2)
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

    /// Spec 03: Quick Add keeps `@person ?kind ~start ^id blockedby:` — every
    /// field the capture line carries comes back out of the index.
    @Test func quickAddEveryTokenRoundTripsThroughIndex() throws {
        let result = try #require(QuickAddParser.parse(
            "?waiting @Amber depends:^ship-v1 ^amber-call &every 2 weeks !p2 ~2026-07-05 >2026-07-20 call Amber #admin",
            today: today, calendar: calendar
        ))
        #expect(result.markdownLine == "- [ ] call Amber #admin >2026-07-20 ~2026-07-05 !p2 &every 2 weeks "
            + "^amber-call blockedby:^ship-v1 @Amber ?waiting")
        let contents = "# Inbox\n\n" + result.markdownLine + "\n"
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "Inbox.md", contents: contents, modifiedAt: nil, today: today)

        let task = try #require(db.openTasks().first)
        #expect(task.text == result.metadata.cleanText)
        #expect(task.dueDate == "2026-07-20")
        #expect(task.startDate == "2026-07-05")
        #expect(task.priority == 2)
        #expect(task.recurrence == "&every 2 weeks")
        #expect(task.blockId == "amber-call")
        #expect(task.dependsOn == "ship-v1")
        #expect(task.assignee == "Amber")
        #expect(task.kind == "waiting")
        #expect(try db.labelsByTaskId()[task.id] == ["admin"])
    }
}

struct NoteTagTests {
    @Test func nestedTagsIndexAndQuery() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "a.md", contents: "# A\nwork on #project/alpha today\n", modifiedAt: nil)
        try indexer.index(noteId: "b.md", contents: "# B\n#project/beta and #home\n", modifiedAt: nil)
        try indexer.index(noteId: "c.md", contents: "# C\nplain #project note\n", modifiedAt: nil)

        let tags = try db.tagsWithCounts()
        #expect(tags.map(\.tag) == ["home", "project", "project/alpha", "project/beta"])
        #expect(try db.noteIds(withTag: "project") == ["a.md", "b.md", "c.md"])
        #expect(try db.noteIds(withTag: "project/alpha") == ["a.md"])
        #expect(try db.noteIds(withTag: "home") == ["b.md"])
    }

    @Test func retaggingReplacesOldRows() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "a.md", contents: "#old\n", modifiedAt: nil)
        try indexer.index(noteId: "a.md", contents: "#new\n", modifiedAt: nil)
        #expect(try db.noteIds(withTag: "old").isEmpty)
        #expect(try db.noteIds(withTag: "new") == ["a.md"])
    }
}

struct NoteFlagTests {
    @Test func frontmatterFlagsIndexAndClear() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(noteId: "p.md", contents: "---\npinned: true\n---\n# P\n", modifiedAt: nil)
        try indexer.index(noteId: "b.md", contents: "---\nbookmarked: true\n---\n# B\n", modifiedAt: nil)
        try indexer.index(noteId: "n.md", contents: "# Plain\n", modifiedAt: nil)
        #expect(try db.pinnedNoteIds() == ["p.md"])
        #expect(try db.bookmarkedNoteIds() == ["b.md"])
        try indexer.index(noteId: "p.md", contents: "---\npinned: false\n---\n# P\n", modifiedAt: nil)
        #expect(try db.pinnedNoteIds().isEmpty)
    }
}

struct ProjectIndexTests {
    @Test func projectFrontmatterIndexesWithProgress() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(
            noteId: "Apollo.md",
            contents: """
            ---
            project: true
            status: active
            start: 2026-07-01
            due: 2026-09-30
            ---
            # Apollo
            - [x] design >2026-07-10
            - [ ] build >2026-08-15
            - [ ] launch >2026-09-30
            """,
            modifiedAt: nil
        )
        try indexer.index(noteId: "plain.md", contents: "# Not a project\n- [ ] chore\n", modifiedAt: nil)

        let projects = try db.projects()
        #expect(projects.map(\.id) == ["Apollo.md"])
        #expect(projects[0].projectStatus == "active")
        #expect(projects[0].projectDue == "2026-09-30")
        let progress = try db.noteTaskProgress()["Apollo.md"]
        #expect(progress?.done == 1)
        #expect(progress?.total == 3)
        #expect(try db.tasks(inNote: "Apollo.md").count == 3)
    }
}

struct DependencyIndexTests {
    @Test func blockIdsAndDependenciesRoundTrip() throws {
        let (db, _) = try IndexDatabase.open(path: nil)
        let indexer = NoteIndexer(database: db)
        try indexer.index(
            noteId: "p.md",
            contents: """
            - [ ] design ^design >2026-07-20
            - [ ] build depends:^design ^build
            - [ ] ship blockedby:design,build
            """,
            modifiedAt: nil
        )
        let tasks = try db.tasks(inNote: "p.md")
        #expect(tasks[0].blockId == "design")
        #expect(tasks[1].dependsOn == "design")
        #expect(tasks[1].blockId == "build")
        #expect(tasks[2].dependsOn == "design build")
        #expect(tasks[2].text == "ship")
    }
}

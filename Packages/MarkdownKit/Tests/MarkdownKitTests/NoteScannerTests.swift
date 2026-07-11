import Foundation
@testable import MarkdownKit
import Testing

struct NoteScannerTests {
    @Test func findsTasksWithLineNumbers() {
        let body = "# Plan\n\n- [ ] first thing\ntext\n- [x] done thing\n"
        let tasks = NoteScanner.tasks(in: body)
        #expect(tasks.count == 2)
        #expect(tasks[0] == ScannedTask(line: 2, rawLine: "- [ ] first thing", checked: false, text: "first thing"))
        #expect(tasks[1].line == 4)
        #expect(tasks[1].checked)
    }

    @Test func supportsIndentedAndOrderedTasks() {
        let body = "  - [ ] nested\n1. [ ] ordered\n* [X] star upper\n"
        let tasks = NoteScanner.tasks(in: body)
        #expect(tasks.count == 3)
        #expect(tasks[2].checked)
    }

    @Test func ignoresNonTasks() {
        let body = "- plain bullet\n[ ] no bullet\n-[ ] no space\n"
        #expect(NoteScanner.tasks(in: body).isEmpty)
    }

    @Test func extractsWikilinkTargets() {
        let body = "See [[Budget]] and [[Deep Plan|the plan]] plus [[Notes#Heading]] and [[Budget]] again.\n"
        #expect(NoteScanner.wikilinkTargets(in: body) == ["Budget", "Deep Plan", "Notes"])
    }

    @Test func extractsTags() {
        let body = "Work on #accreditation and #courses/phar7315 today. Ignore code#notatag.\n"
        #expect(NoteScanner.tags(in: body) == ["accreditation", "courses/phar7315"])
    }
}

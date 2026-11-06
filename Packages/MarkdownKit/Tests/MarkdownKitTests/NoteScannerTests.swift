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

    @Test func pathQualifiedTargetIndexesTitle() {
        let body = "See [[Projects/Plan]] and [[Plan|again]] and [[Archive/2025/Budget#Q1]].\n"
        #expect(NoteScanner.wikilinkTargets(in: body) == ["Plan", "Budget"])
    }

    @Test func linksInCodeAreLiteralNotIndexed() {
        let body = "Use `[[Plan]]` syntax.\n\n```\n[[Fenced]]\n```\n\n~~~\n[[Tilde]]\n~~~\n\nReal [[Budget]].\n"
        #expect(NoteScanner.wikilinkTargets(in: body) == ["Budget"])
        #expect(NoteScanner.wikilinkTargets(in: "Only `[[Plan]]` here.\n") == [])
        // Code elsewhere in the note doesn't hide a real link of the same title.
        #expect(NoteScanner.wikilinkTargets(in: "`[[Plan]]` and [[Plan]]\n") == ["Plan"])
    }

    @Test func codeRangesCoverSpansAndBlocks() {
        let body = "a `[[x]]` b\n\n```\n[[y]]\n```\n"
        let ns = body as NSString
        let spans = MarkdownStyler.codeRanges(in: body).map { ns.substring(with: $0) }
        #expect(spans.count == 2)
        #expect(spans.contains("`[[x]]`"))
        #expect(spans.contains { $0.hasPrefix("```") && $0.contains("[[y]]") })
    }

    @Test func selfAndEmptyLinksIndexNothing() {
        #expect(NoteScanner.wikilinkTargets(in: "[[#Heading]] and [[ ]] and [[|alias]]\n") == [])
    }

    @Test func extractsTags() {
        let body = "Work on #accreditation and #courses/phar7315 today. Ignore code#notatag.\n"
        #expect(NoteScanner.tags(in: body) == ["accreditation", "courses/phar7315"])
    }
}

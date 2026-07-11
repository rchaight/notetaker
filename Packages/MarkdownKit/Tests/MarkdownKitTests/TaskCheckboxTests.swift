import Foundation
@testable import MarkdownKit
import Testing

struct TaskCheckboxTests {
    private func tokens(_ text: String) -> [(String, Bool)] {
        TaskCheckboxes.tokens(in: text, styled: MarkdownStyler.styleRanges(in: text))
            .map { ((text as NSString).substring(with: $0.range), $0.checked) }
    }

    @Test func findsUncheckedAndCheckedTokens() {
        let found = tokens("- [ ] open\n- [x] done\n")
        #expect(found.count == 2)
        #expect(found[0] == ("[ ]", false))
        #expect(found[1] == ("[x]", true))
    }

    @Test func ignoresPlainListItems() {
        #expect(tokens("- not a task\n- [ ] a task\n").count == 1)
    }

    @Test func emojiOffsetsStayCorrect() {
        let text = "🚀 intro\n\n- [ ] launch\n"
        let found = TaskCheckboxes.tokens(in: text, styled: MarkdownStyler.styleRanges(in: text))
        #expect(found.count == 1)
        #expect((text as NSString).substring(with: found[0].range) == "[ ]")
    }

    @Test func togglesBothDirections() {
        let text = "- [ ] call\n"
        let range = TaskCheckboxes.tokens(in: text, styled: MarkdownStyler.styleRanges(in: text))[0].range
        let checked = TaskCheckboxes.toggled(text, tokenAt: range)
        #expect(checked == "- [x] call\n")
        let unchecked = checked.flatMap { TaskCheckboxes.toggled($0, tokenAt: range) }
        #expect(unchecked == text)
    }

    @Test func toggleRefusesDriftedRange() {
        #expect(TaskCheckboxes.toggled("- [ ] ok\n", tokenAt: NSRange(location: 0, length: 3)) == nil)
        #expect(TaskCheckboxes.toggled("hi", tokenAt: NSRange(location: 0, length: 3)) == nil)
    }
}

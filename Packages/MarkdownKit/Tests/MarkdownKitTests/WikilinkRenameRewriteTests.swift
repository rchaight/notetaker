import Foundation
@testable import MarkdownKit
import Testing

/// The composition every rename write goes through (specs/ux-phase2/05): frontmatter and
/// code exclusion plus the "same title, different note" resolve filter.
struct WikilinkRenameRewriteTests {
    private let notes: [(id: String, title: String)] = [
        ("Plan.md", "Plan"), ("Projects/Plan.md", "Plan"), ("Daily.md", "Daily"),
    ]

    private func rewrite(
        _ text: String, sourceId: String = "Daily.md", renamedId: String = "Plan.md"
    ) -> (text: String, count: Int) {
        WikilinkRenameRewrite.rewrite(
            text, sourceId: sourceId, renamingTitle: "Plan", to: "Strategy",
            renamedId: renamedId, among: notes
        )
    }

    @Test func rewritesALinkThatResolvesToTheRenamedNote() {
        let result = rewrite("See [[Plan]] now.")
        #expect(result.text == "See [[Strategy]] now.")
        #expect(result.count == 1)
    }

    @Test func leavesALinkThatResolvesToADifferentNoteWithTheSameTitle() {
        // From the root, `[[Plan]]` is Plan.md (same folder wins); renaming Projects/Plan.md
        // must not touch it, while the path-qualified link to the renamed note is rewritten.
        let text = "[[Plan]] and [[Projects/Plan]]"
        let result = rewrite(text, renamedId: "Projects/Plan.md")
        #expect(result.text == "[[Plan]] and [[Projects/Strategy]]")
        #expect(result.count == 1)
        let untouched = rewrite("[[Plan]]", renamedId: "Projects/Plan.md")
        #expect(untouched.text == "[[Plan]]")
        #expect(untouched.count == 0)
    }

    @Test func leavesFrontmatterAlone() {
        let text = "---\nrelated: \"[[Plan]]\"\n---\n[[Plan]]\n"
        let result = rewrite(text)
        #expect(result.text == "---\nrelated: \"[[Plan]]\"\n---\n[[Strategy]]\n")
        #expect(result.count == 1)
    }

    @Test func leavesCodeSpansAndFencesAlone() {
        let text = "`[[Plan]]` and [[Plan]]\n\n```\n[[Plan]]\n```\n\n~~~\n[[Plan]]\n~~~\n"
        let result = rewrite(text)
        #expect(result.text == "`[[Plan]]` and [[Strategy]]\n\n```\n[[Plan]]\n```\n\n~~~\n[[Plan]]\n~~~\n")
        #expect(result.count == 1)
    }

    @Test func aliasHeadingBlockAndPathFormsSurvive() {
        let text = "[[Plan|the plan]] [[Plan#Budget]] [[plan#^abc|x]] [[Plan ]] ![[Plan]]"
        let result = rewrite(text)
        let expected = "[[Strategy|the plan]] [[Strategy#Budget]] [[Strategy#^abc|x]] "
            + "[[Strategy ]] ![[Strategy]]"
        #expect(result.text == expected)
        #expect(result.count == 5)
        let pathed = rewrite("[[Projects/Plan#Goals|g]]", renamedId: "Projects/Plan.md")
        #expect(pathed.text == "[[Projects/Strategy#Goals|g]]")
    }

    @Test func secondRunIsANoOp() {
        let first = rewrite("[[Plan]] [[Plan|x]]\n`[[Plan]]`")
        #expect(first.count == 2)
        let second = WikilinkRenameRewrite.rewrite(
            first.text, sourceId: "Daily.md", renamingTitle: "Plan", to: "Strategy",
            renamedId: "Plan.md", among: notes
        )
        #expect(second.text == first.text)
        #expect(second.count == 0)
    }
}

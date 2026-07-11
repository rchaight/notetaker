import Foundation
@testable import MarkdownKit
import Testing

struct TaskLineTogglerTests {
    let contents = "# Plan\n\n- [ ] email dean\n- [x] book room\n"

    @Test func togglesAtAnchor() {
        let result = TaskLineToggler.toggle(
            contents: contents, anchorLine: 2, expectedRawLine: "- [ ] email dean"
        )
        #expect(result?.contents == "# Plan\n\n- [x] email dean\n- [x] book room\n")
        #expect(result?.line == 2)
        #expect(result?.nowChecked == true)
    }

    @Test func unchecksCheckedTask() {
        let result = TaskLineToggler.toggle(
            contents: contents, anchorLine: 3, expectedRawLine: "- [x] book room"
        )
        #expect(result?.contents == "# Plan\n\n- [ ] email dean\n- [ ] book room\n")
        #expect(result?.nowChecked == false)
    }

    @Test func relocatesMovedLine() {
        // Two lines were inserted above since indexing.
        let drifted = "new intro\nanother line\n" + contents
        let result = TaskLineToggler.toggle(
            contents: drifted, anchorLine: 2, expectedRawLine: "- [ ] email dean"
        )
        #expect(result?.line == 4)
        #expect(result?.contents.contains("- [x] email dean") == true)
    }

    @Test func refusesWhenLineContentChanged() {
        // The task text was edited since indexing — refuse, don't guess.
        let result = TaskLineToggler.toggle(
            contents: contents, anchorLine: 2, expectedRawLine: "- [ ] email the provost"
        )
        #expect(result == nil)
    }

    @Test func preservesEverythingElseByteForByte() {
        let tricky = "---\ntitle: x\n---\n\n- [ ] task **bold** #tag >2026-07-15\n\ttabbed line\n"
        let result = TaskLineToggler.toggle(
            contents: tricky, anchorLine: 4,
            expectedRawLine: "- [ ] task **bold** #tag >2026-07-15"
        )
        #expect(result?.contents == "---\ntitle: x\n---\n\n- [x] task **bold** #tag >2026-07-15\n\ttabbed line\n")
    }
}

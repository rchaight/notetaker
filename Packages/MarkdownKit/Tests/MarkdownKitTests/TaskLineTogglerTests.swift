import Foundation
@testable import MarkdownKit
import Testing

/// `TaskLineToggler` only ADDRESSES lines (locate / replace / remove); what a
/// completed line says is `RecurrenceEngine.completeTaskLine`'s job and is
/// tested in TaskEngine (`TaskCompletionTests`).
struct TaskLineTogglerTests {
    let contents = "# Plan\n\n- [ ] email dean\n- [x] book room\n"

    @Test func locatesAtAnchor() {
        #expect(TaskLineToggler.locate(
            contents: contents, anchorLine: 2, expectedRawLine: "- [ ] email dean"
        ) == 2)
        #expect(TaskLineToggler.locate(
            contents: contents, anchorLine: 3, expectedRawLine: "- [x] book room"
        ) == 3)
    }

    @Test func relocatesMovedLine() {
        // Two lines were inserted above since indexing.
        let drifted = "new intro\nanother line\n" + contents
        #expect(TaskLineToggler.locate(
            contents: drifted, anchorLine: 2, expectedRawLine: "- [ ] email dean"
        ) == 4)
    }

    @Test func refusesWhenLineContentChanged() {
        // The task text was edited since indexing — refuse, don't guess.
        #expect(TaskLineToggler.locate(
            contents: contents, anchorLine: 2, expectedRawLine: "- [ ] email the provost"
        ) == nil)
    }

    @Test func replacingLinePreservesEverythingElseByteForByte() {
        let tricky = "---\ntitle: x\n---\n\n- [ ] task **bold** #tag >2026-07-15\n\ttabbed line\n"
        let line = TaskLineToggler.locate(
            contents: tricky, anchorLine: 4, expectedRawLine: "- [ ] task **bold** #tag >2026-07-15"
        )
        #expect(line == 4)
        let result = TaskLineToggler.replacingLine(
            tricky, at: 4, with: "- [x] task **bold** #tag >2026-07-15 ✅2026-07-14"
        )
        #expect(result == "---\ntitle: x\n---\n\n- [x] task **bold** #tag >2026-07-15 ✅2026-07-14\n\ttabbed line\n")
    }

    @Test func replacingLineOutOfRangeIsANoOp() {
        #expect(TaskLineToggler.replacingLine(contents, at: 99, with: "x") == contents)
        #expect(TaskLineToggler.replacingLine(contents, at: -1, with: "x") == contents)
    }
}

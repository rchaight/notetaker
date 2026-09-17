@testable import EditorKit
import Foundation
import MarkdownKit
import Testing

/// The exclusion oracle: which spans of a note are markup rather than
/// prose, and therefore must never reach a spell or grammar checker.
struct ProofingExclusionTests {
    private func exclusions(_ text: String) -> [NSRange] {
        ProofingExclusions.ranges(in: text, styled: MarkdownStyler.styleRanges(in: text))
    }

    /// True when every UTF-16 unit of `needle`'s first occurrence is
    /// excluded. Prose assertions use the negation, so a partial overlap
    /// fails both ways rather than passing quietly.
    private func excluded(_ needle: String, in text: String) -> Bool {
        let ns = text as NSString
        let target = ns.range(of: needle)
        guard target.location != NSNotFound else {
            Issue.record("\(needle) is not in the fixture")
            return false
        }
        let covered = exclusions(text).reduce(0) { total, range in
            total + NSIntersectionRange(range, target).length
        }
        return covered == target.length
    }

    @Test func inlineCodeIsExcluded() {
        let text = "Run `defaults wrte com.example` before shipping.\n"
        #expect(excluded("`defaults wrte com.example`", in: text))
        #expect(!excluded("before shipping", in: text))
    }

    @Test func fencedCodeBlocksAreExcluded() {
        let text = """
        Notes about the script.

        ```swift
        let mispeled = "definately"
        ```

        Back to prose.
        """
        #expect(excluded("let mispeled", in: text))
        #expect(excluded("definately", in: text))
        #expect(!excluded("Notes about the script.", in: text))
        #expect(!excluded("Back to prose.", in: text))
    }

    @Test func frontmatterIsExcludedWhenPresent() {
        let text = """
        ---
        title: Kickoff
        project: qol-workforce
        ---

        The kickoff went well.
        """
        #expect(excluded("project: qol-workforce", in: text))
        #expect(!excluded("The kickoff went well.", in: text))
    }

    @Test func withoutFrontmatterNothingAtTheTopIsExcluded() {
        let text = "Kickoff notes for the qol project.\n"
        #expect(exclusions(text).isEmpty)
    }

    @Test func linkDestinationsGoButLabelsStay() {
        let text = "See [the enrollment memo](https://example.com/enrolment-memo.pdf) today.\n"
        #expect(excluded("https://example.com/enrolment-memo.pdf", in: text))
        // The label is the part a human wrote and reads — keep it checkable.
        #expect(!excluded("the enrollment memo", in: text))
        #expect(!excluded("today", in: text))
        // The opening bracket is syntax too — left in, LanguageTool sees an
        // orphan `[` and raises UNPAIRED_BRACKETS on every linked sentence.
        #expect(excluded("[", in: text))
    }

    @Test func bareAndAngleURLsAreExcluded() {
        let bare = "Docs live at https://unthsc.edu/asessment/handbook now.\n"
        #expect(excluded("https://unthsc.edu/asessment/handbook", in: bare))
        #expect(!excluded("Docs live at", in: bare))
        let angle = "Mirror: <https://unthsc.edu/asessment> for now.\n"
        #expect(excluded("<https://unthsc.edu/asessment>", in: angle))
        let www = "Try www.unthsc.edu/asessment for the form.\n"
        #expect(excluded("www.unthsc.edu/asessment", in: www))
    }

    @Test func imagesAndWikilinksAreExcluded() {
        let text = "![screnshot](Attachments/screnshot.png) and [[Weekly Cadance Note]] here.\n"
        #expect(excluded("![screnshot](Attachments/screnshot.png)", in: text))
        #expect(excluded("[[Weekly Cadance Note]]", in: text))
        #expect(!excluded("here", in: text))
    }

    @Test func chipTokensAreExcluded() {
        let text = "Reviewed with @amberh on #qol-wrkforce ?discuss and it went fine.\n"
        #expect(excluded("@amberh", in: text))
        #expect(excluded("#qol-wrkforce", in: text))
        #expect(excluded("?discuss", in: text))
        #expect(!excluded("Reviewed with", in: text))
        #expect(!excluded("and it went fine", in: text))
    }

    @Test func taskLineTokensAreExcluded() {
        let text = "- [ ] draft the memo >friday !p1 &every 2 weeks ^memo "
            + "blockedby:^spec ✅2026-07-14\n"
        for token in [">friday", "!p1", "&every 2 weeks", "^memo", "blockedby:^spec", "✅2026-07-14"] {
            #expect(excluded(token, in: text), "\(token) was left checkable")
        }
        #expect(!excluded("draft the memo", in: text))
    }

    @Test func tokensOffATaskLineStayProse() {
        // `>friday` only means "due date" inside a task; in a sentence the
        // words around it are ordinary prose, and nothing here is a task.
        let text = "The deadline moved to friday and the plan holds.\n"
        #expect(exclusions(text).isEmpty)
    }

    @Test func proseAdjacentToATokenIsNotExcluded() {
        let text = "- [ ] recieve the packet #intake >today\n"
        // The misspelling sits one space from a chip and one from a date.
        #expect(!excluded("recieve", in: text))
        #expect(excluded("#intake", in: text))
        #expect(excluded(">today", in: text))
    }

    @Test func adjacentAndOverlappingRangesCoalesce() {
        // Two chips separated by a single space: three spans (chip, gap is
        // prose, chip) must stay two, but abutting ones must merge.
        #expect(ProofingExclusions.coalesced([
            NSRange(location: 0, length: 5),
            NSRange(location: 5, length: 5),
        ]) == [NSRange(location: 0, length: 10)])
        #expect(ProofingExclusions.coalesced([
            NSRange(location: 3, length: 4),
            NSRange(location: 0, length: 5),
        ]) == [NSRange(location: 0, length: 7)])
        #expect(ProofingExclusions.coalesced([
            NSRange(location: 0, length: 2),
            NSRange(location: 4, length: 2),
        ]) == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        #expect(ProofingExclusions.coalesced([]) == [])
        // Zero-length spans (an absent frontmatter block) never survive.
        #expect(ProofingExclusions.coalesced([NSRange(location: 3, length: 0)]) == [])
    }

    @Test func ranges_areSortedAndNonOverlapping() {
        let text = "---\ntitle: T\n---\n\nSee `code` and #tag and [x](https://e.com/a).\n"
        let ranges = exclusions(text)
        #expect(ranges.count > 1)
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(earlier) < later.location)
        }
    }

    @Test func crlfTextKeepsItsRangesInBounds() {
        let text = "---\r\ntitle: T\r\n---\r\n\r\n- [ ] recieve it >friday #tag\r\n"
        let ns = text as NSString
        let ranges = exclusions(text)
        #expect(!ranges.isEmpty)
        for range in ranges {
            #expect(range.location >= 0)
            #expect(NSMaxRange(range) <= ns.length)
        }
        #expect(excluded(">friday", in: text))
        #expect(!excluded("recieve", in: text))
    }

    @Test func emptyTextHasNoExclusions() {
        #expect(ProofingExclusions.ranges(in: "", styled: []).isEmpty)
        #expect(exclusions("\n").isEmpty)
    }

    /// The coordinate contract: ranges come back relative to the enclosing
    /// range (UIKit's header for the same delegate method: "ranges in the
    /// attributed substring of the textView storage with the enclosing
    /// range"), clipped to it.
    @Test func writingToolsRangesAreRebasedOntoTheEnclosingRange() {
        let text = "one #tag two #other three\n"
        let styled = MarkdownStyler.styleRanges(in: text)
        let ns = text as NSString
        let all = ProofingExclusions.ranges(in: text, styled: styled)
        let firstTag = ns.range(of: "#tag")

        // Whole document: enclosing.location == 0, so the two readings of
        // the contract coincide and the ranges are the absolute ones.
        let whole = ProofingExclusions.writingToolsIgnoredRanges(
            in: text, styled: styled, enclosing: NSRange(location: 0, length: ns.length)
        )
        #expect(whole == all)

        // A window that starts mid-note: every range shifts back by the
        // window's own start.
        let window = NSRange(location: firstTag.location, length: ns.length - firstTag.location)
        let rebased = ProofingExclusions.writingToolsIgnoredRanges(
            in: text, styled: styled, enclosing: window
        )
        #expect(rebased.first == NSRange(location: 0, length: firstTag.length))
        for range in rebased {
            #expect(range.location >= 0)
            #expect(NSMaxRange(range) <= window.length)
        }

        // A window that cuts a token in half keeps only the part inside.
        let half = NSRange(location: firstTag.location + 2, length: 4)
        let clipped = ProofingExclusions.writingToolsIgnoredRanges(
            in: text, styled: styled, enclosing: half
        )
        #expect(clipped == [NSRange(location: 0, length: 2)])
        #expect(ProofingExclusions.writingToolsIgnoredRanges(
            in: text, styled: styled, enclosing: NSRange(location: 0, length: 0)
        ).isEmpty)
    }

    @Test func keepingDropsProofingResultsInsideMarkupOnly() {
        let exclusions = [NSRange(location: 10, length: 5)]
        let inside = NSTextCheckingResult.spellCheckingResult(range: NSRange(location: 11, length: 3))
        let outside = NSTextCheckingResult.spellCheckingResult(range: NSRange(location: 0, length: 3))
        let orthography = NSTextCheckingResult.orthographyCheckingResult(
            range: NSRange(location: 0, length: 40),
            orthography: NSOrthography(
                dominantScript: "Latn", languageMap: ["Latn": ["en"]]
            )
        )
        let kept = ProofingExclusions.keeping([inside, outside, orthography], excluding: exclusions)
        #expect(kept.count == 2)
        #expect(kept.contains { $0.range == outside.range })
        // The whole-document language report survives even though it
        // overlaps every exclusion in the note.
        #expect(kept.contains { $0.resultType == .orthography })
        // No exclusions: nothing is dropped.
        #expect(ProofingExclusions.keeping([inside, outside], excluding: []).count == 2)
    }
}

@testable import EditorKit
import Foundation
import MarkdownKit
import Testing

struct WikilinkHitTestTests {
    private let text = "see [[Plan 2026]] now"

    private func offset(of needle: String, in haystack: String) -> Int {
        (haystack as NSString).range(of: needle).location
    }

    @Test func hitInsideBracketsReturnsLink() throws {
        let inside = offset(of: "Plan", in: text) + 2
        let link = try #require(WikilinkHitTest.link(at: inside, in: text))
        #expect(link.target == "Plan 2026")
        #expect(link.range == NSRange(location: 4, length: 13))
        #expect((text as NSString).substring(with: link.range) == "[[Plan 2026]]")
    }

    @Test func hitOnBracketCharacterCounts() {
        let open = offset(of: "[[", in: text)
        #expect(WikilinkHitTest.link(at: open, in: text)?.target == "Plan 2026", "first bracket")
        #expect(WikilinkHitTest.link(at: open + 1, in: text)?.target == "Plan 2026", "second bracket")
        let close = offset(of: "]]", in: text)
        #expect(WikilinkHitTest.link(at: close, in: text)?.target == "Plan 2026")
        #expect(WikilinkHitTest.link(at: close + 1, in: text)?.target == "Plan 2026", "last bracket")
    }

    @Test func hitOutsideReturnsNil() {
        #expect(WikilinkHitTest.link(at: 0, in: text) == nil)
        #expect(WikilinkHitTest.link(at: offset(of: "[[", in: text) - 1, in: text) == nil, "the space before")
        #expect(WikilinkHitTest.link(at: NSMaxRange((text as NSString).range(of: "]]")), in: text) == nil,
                "the boundary just past the closing brackets")
        #expect(WikilinkHitTest.link(at: (text as NSString).length, in: text) == nil)
        #expect(WikilinkHitTest.link(at: -1, in: text) == nil)
        #expect(WikilinkHitTest.link(at: 999, in: text) == nil)
        #expect(WikilinkHitTest.link(at: 3, in: "no links here") == nil)
        #expect(WikilinkHitTest.link(at: 0, in: "") == nil)
    }

    @Test func hitUsesParagraphLocalScanWithFullTextRanges() throws {
        let multi = "first paragraph [[One]]\n\nsecond with no link\nthird [[Two|alias]] and [[Three]] end\n"
        let ns = multi as NSString
        let two = try #require(WikilinkHitTest.link(at: ns.range(of: "Two").location, in: multi))
        #expect(two.target == "Two")
        #expect(two.range == ns.range(of: "[[Two|alias]]"), "range is in whole-text coordinates")
        #expect(ns.substring(with: two.targetRange) == "Two")

        let three = try #require(WikilinkHitTest.link(at: ns.range(of: "Three").location + 1, in: multi))
        #expect(three.range == ns.range(of: "[[Three]]"))
        #expect(ns.substring(with: three.targetRange) == "Three")

        let one = try #require(WikilinkHitTest.link(at: ns.range(of: "One").location, in: multi))
        #expect(one.range == ns.range(of: "[[One]]"))
        // The blank line and the link-free paragraph hit nothing.
        #expect(WikilinkHitTest.link(at: ns.range(of: "no link").location, in: multi) == nil)
        // A link on another line is not "near" this index.
        #expect(WikilinkHitTest.link(at: ns.range(of: "third").location, in: multi) == nil)
    }

    @Test func aliasAndHeadingSurvive() throws {
        let source = "x [[Plan#Budget|the budget]] y"
        let link = try #require(WikilinkHitTest.link(at: offset(of: "Budget", in: source), in: source))
        #expect(link.target == "Plan")
        #expect(link.heading == "Budget")
        #expect(link.alias == "the budget")
        #expect(link.raw == "Plan#Budget|the budget")
        #expect(link.label == "the budget")
        let block = "[[Plan#^abc12]]"
        #expect(WikilinkHitTest.link(at: 3, in: block)?.blockId == "abc12")
    }

    @Test func utf16OffsetsFollowEmoji() throws {
        let source = "🙂 [[Plan]]"
        let ns = source as NSString
        let link = try #require(WikilinkHitTest.link(at: ns.range(of: "Plan").location, in: source))
        #expect(link.range == ns.range(of: "[[Plan]]"))
        #expect(WikilinkHitTest.link(at: 0, in: source) == nil)
    }

    @Test func embedsHit() throws {
        let source = "![[Plan]]"
        let link = try #require(WikilinkHitTest.link(at: 0, in: source))
        #expect(link.isEmbed)
        #expect(link.range == NSRange(location: 0, length: 9))
    }
}

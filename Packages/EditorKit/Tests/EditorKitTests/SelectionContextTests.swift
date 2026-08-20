@testable import EditorKit
import Foundation
import MarkdownKit
import Testing

struct SelectionContextTests {
    /// A zero-length caret placed `offset` UTF-16 units into the first
    /// occurrence of `needle` — avoids brittle hand-counted indices.
    private func caret(in text: String, at needle: String, offset: Int = 1) -> NSRange {
        let found = (text as NSString).range(of: needle)
        precondition(found.location != NSNotFound, "fixture text must contain \(needle)")
        return NSRange(location: found.location + offset, length: 0)
    }

    private func context(_ text: String, at needle: String, offset: Int = 1) -> SelectionContext {
        let ranges = MarkdownStyler.styleRanges(in: text)
        return SelectionContext.at(caret(in: text, at: needle, offset: offset), ranges: ranges)
    }

    @Test func boldActiveWhenCaretInsideBoldRange() {
        let ctx = context("make **this** bold", at: "this", offset: 2)
        #expect(ctx.bold)
        #expect(!ctx.italic)
    }

    @Test func italicActiveWhenCaretInsideEmphasisRange() {
        let ctx = context("make *this* italic", at: "this", offset: 2)
        #expect(ctx.italic)
        #expect(!ctx.bold)
    }

    @Test func nestedBoldAndItalicBothActive() {
        let ctx = context("a **b *c* d** e", at: "c", offset: 0)
        #expect(ctx.bold)
        #expect(ctx.italic)
    }

    @Test func strikethroughActiveInsideStrikethroughRange() {
        let ctx = context("a ~~gone~~ b", at: "gone", offset: 1)
        #expect(ctx.strikethrough)
    }

    @Test func inlineCodeActiveInsideBackticks() {
        let ctx = context("run `swift build` now", at: "swift", offset: 1)
        #expect(ctx.code)
        #expect(!ctx.bold)
    }

    @Test func headingLevelOneForTitle() {
        let ctx = context("# Title\n\nBody text", at: "Title", offset: 1)
        #expect(ctx.headingLevel == 1)
    }

    @Test func headingLevelThreeForSubheading() {
        let ctx = context("### Subheading\n\nBody text", at: "Subheading", offset: 1)
        #expect(ctx.headingLevel == 3)
    }

    @Test func headingLevelZeroInBodyText() {
        let ctx = context("# Title\n\nBody text here", at: "Body", offset: 1)
        #expect(ctx.headingLevel == 0)
    }

    @Test func codeBlockSuppressesInlineStyles() {
        let text = "```\nlet x = 1\n```\n\nafter"
        let ctx = context(text, at: "let x", offset: 2)
        #expect(ctx.inCodeBlock)
        #expect(!ctx.bold)
        #expect(!ctx.italic)
        #expect(ctx.headingLevel == 0)
    }

    @Test func linkDetectionReturnsRangeAndDestination() throws {
        let text = "See [my link](https://example.com) for more"
        let ranges = MarkdownStyler.styleRanges(in: text)
        let selection = caret(in: text, at: "my link", offset: 2)
        let ctx = SelectionContext.at(selection, ranges: ranges)
        let link = try #require(ctx.link)
        #expect(link.destination == "https://example.com")
        let ns = text as NSString
        #expect(ns.substring(with: link.range) == "[my link](https://example.com)")
    }

    @Test func tableFlagActiveInsideTable() {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let ctx = context(text, at: "1", offset: 0)
        #expect(ctx.inTable)
    }

    @Test func listFlagActiveInsideListItem() {
        let text = "- item one\n- item two"
        let ctx = context(text, at: "item one", offset: 2)
        #expect(ctx.inList)
    }

    @Test func quoteFlagActiveInsideBlockQuote() {
        let text = "> quoted text"
        let ctx = context(text, at: "quoted", offset: 2)
        #expect(ctx.inQuote)
    }

    @Test func plainTextAllFalse() {
        let ctx = context("just plain text", at: "plain", offset: 1)
        #expect(ctx == SelectionContext())
    }

    @Test func equalContextsCompareEqualForSkipPublishing() {
        let text = "make **this** bold"
        let ranges = MarkdownStyler.styleRanges(in: text)
        let a = SelectionContext.at(caret(in: text, at: "this", offset: 1), ranges: ranges)
        let b = SelectionContext.at(caret(in: text, at: "this", offset: 2), ranges: ranges)
        #expect(a == b)
    }
}

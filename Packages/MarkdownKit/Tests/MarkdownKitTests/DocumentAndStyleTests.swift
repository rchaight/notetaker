import Foundation
@testable import MarkdownKit
import Testing

struct FrontmatterTests {
    @Test func splitsAndRoundTrips() {
        let source = "---\ntitle: Big Plan\nstatus: active\n---\n# Heading\n\nBody text.\n"
        let doc = MarkdownDocument(source: source)
        #expect(doc.frontmatter?.values["title"] == "Big Plan")
        #expect(doc.frontmatter?.values["status"] == "active")
        #expect(doc.body == "# Heading\n\nBody text.\n")
        #expect(doc.render() == source)
        #expect(doc.bodyUTF16Offset == "---\ntitle: Big Plan\nstatus: active\n---\n".utf16.count)
    }

    @Test func noFrontmatterMeansWholeBody() {
        let source = "# Just a note\n"
        let doc = MarkdownDocument(source: source)
        #expect(doc.frontmatter == nil)
        #expect(doc.body == source)
        #expect(doc.bodyUTF16Offset == 0)
        #expect(doc.render() == source)
    }

    @Test func unclosedFenceIsBody() {
        let source = "---\ntitle: oops\nno closing fence\n"
        let doc = MarkdownDocument(source: source)
        #expect(doc.frontmatter == nil)
        #expect(doc.body == source)
    }

    @Test func buildsBlockFromValues() {
        let frontmatter = Frontmatter(values: ["title": "New", "project": "notetaker"])
        #expect(frontmatter.rawBlock == "---\nproject: notetaker\ntitle: New\n---\n")
        let doc = MarkdownDocument(frontmatter: frontmatter, body: "content\n")
        #expect(doc.render() == "---\nproject: notetaker\ntitle: New\n---\ncontent\n")
    }
}

struct StyleRangeTests {
    private func kinds(_ body: String) -> [MarkdownElementKind] {
        MarkdownStyler.styleRanges(in: body).map(\.kind)
    }

    private func range(_ body: String, _ kind: MarkdownElementKind) -> NSRange? {
        MarkdownStyler.styleRanges(in: body).first { $0.kind == kind }?.range
    }

    @Test func headingRangeCoversLine() {
        let body = "# Title\n\nplain\n"
        let headingRange = range(body, .heading(level: 1))
        #expect(headingRange == NSRange(location: 0, length: "# Title".utf16.count))
    }

    @Test func strongAndEmphasisRanges() {
        let body = "some **bold** and *lean* text\n"
        let strong = range(body, .strong)
        let emphasis = range(body, .emphasis)
        #expect(strong.map { (body as NSString).substring(with: $0) } == "**bold**")
        #expect(emphasis.map { (body as NSString).substring(with: $0) } == "*lean*")
    }

    @Test func utf16OffsetsSurviveEmoji() {
        let body = "🚀🚀 **bold**\n"
        let strong = range(body, .strong)
        #expect(strong.map { (body as NSString).substring(with: $0) } == "**bold**")
    }

    @Test func taskCheckboxStates() {
        let body = "- [ ] open task\n- [x] done task\n"
        let all = MarkdownStyler.styleRanges(in: body)
        #expect(all.contains { $0.kind == .taskCheckbox(checked: false) })
        #expect(all.contains { $0.kind == .taskCheckbox(checked: true) })
        #expect(all.filter { $0.kind == .listItem }.count == 2)
    }

    @Test func fencedCodeBlockWithLanguage() {
        let body = "```swift\nlet x = 1\n```\n"
        #expect(kinds(body).contains(.codeBlock(language: "swift")))
    }

    @Test func inlineCodeAndLink() {
        let body = "see `run()` at [docs](https://example.com)\n"
        #expect(kinds(body).contains(.inlineCode))
        #expect(kinds(body).contains(.link(destination: "https://example.com")))
    }

    @Test func rangesAreSortedByLocation() {
        let body = "# H\n\n**a** then *b*\n\n> quote\n"
        let locations = MarkdownStyler.styleRanges(in: body).map(\.range.location)
        #expect(locations == locations.sorted())
    }
}

import Foundation
@testable import MarkdownKit
import Testing

struct SyntaxMarkerTests {
    private func markers(_ text: String) -> [String] {
        let styled = MarkdownStyler.styleRanges(in: text)
        return SyntaxMarkers.markerRanges(in: text, styled: styled)
            .sorted { ($0.location, $0.length) < ($1.location, $1.length) }
            .map { (text as NSString).substring(with: $0) }
    }

    @Test func headingMarkers() {
        #expect(markers("## Section\n") == ["## "])
    }

    @Test func strongAndEmphasisMarkers() {
        #expect(markers("**bold**\n") == ["**", "**"])
        #expect(markers("*lean*\n") == ["*", "*"])
        #expect(markers("_lean_\n") == ["_", "_"])
    }

    @Test func strikethroughMarkers() {
        #expect(markers("~~gone~~\n") == ["~~", "~~"])
    }

    @Test func inlineCodeMarkers() {
        #expect(markers("`run()`\n") == ["`", "`"])
    }

    @Test func linkMarkersHidePlumbing() {
        let found = markers("[docs](https://example.com)\n")
        #expect(found == ["[", "](https://example.com)"])
    }

    @Test func emojiBeforeMarkersKeepsOffsetsRight() {
        let text = "🚀 **bold**\n"
        let ranges = SyntaxMarkers.markerRanges(
            in: text, styled: MarkdownStyler.styleRanges(in: text)
        )
        let pieces = ranges.map { (text as NSString).substring(with: $0) }
        #expect(pieces == ["**", "**"])
    }

    @Test func plainTextHasNoMarkers() {
        #expect(markers("just words\n").isEmpty)
    }

    @Test func blockquoteMarkersHidden() {
        #expect(markers("> quoted wisdom\n") == ["> "])
    }

    @Test func nestedBlockquoteMarkersHidden() {
        #expect(markers("> > deep quote\n") == ["> > "])
    }

    @Test func fencedCodeBlockHidesFenceLines() {
        let found = markers("```swift\nlet x = 1\n```\n")
        #expect(found.contains("```swift"))
        #expect(found.contains("```"))
    }

    @Test func listMarkersAreNotHidden() {
        // Bullets/checkboxes render as glyphs via display substitution;
        // ordered numbers stay visible. The hider leaves all of them alone.
        #expect(markers("- first\n- second\n").isEmpty)
        #expect(markers("1. first\n2. second\n").isEmpty)
        #expect(markers("- [ ] call the dean\n").isEmpty)
    }
}

struct ExtendedSyntaxTests {
    private func kinds(_ text: String) -> [MarkdownElementKind] {
        MarkdownStyler.styleRanges(in: text).map(\.kind)
    }

    @Test func wikilinkDetectedWithTarget() {
        let styled = MarkdownStyler.styleRanges(in: "see [[Project Plan]] for details\n")
        let link = styled.first { if case .wikilink = $0.kind { true } else { false } }
        #expect(link?.kind == .wikilink(target: "Project Plan"))
        #expect(link?.range == NSRange(location: 4, length: 16))
    }

    @Test func highlightMarkDetected() {
        #expect(kinds("this is ==important== stuff\n").contains(.highlightMark))
    }

    @Test func extendedSyntaxIgnoredInsideCode() {
        let inline = kinds("`[[not a link]]` and `==not marked==`\n")
        #expect(!inline.contains { if case .wikilink = $0 { true } else { false } })
        #expect(!inline.contains(.highlightMark))
        let fenced = kinds("```\n[[nope]] ==nope==\n```\n")
        #expect(!fenced.contains { if case .wikilink = $0 { true } else { false } })
        #expect(!fenced.contains(.highlightMark))
    }

    @Test func wikilinkAndHighlightMarkersHide() {
        let text = "[[Note]] and ==bright==\n"
        let styled = MarkdownStyler.styleRanges(in: text)
        let markers = SyntaxMarkers.markerRanges(in: text, styled: styled)
            .map { (text as NSString).substring(with: $0) }
        #expect(markers.sorted() == ["==", "==", "[[", "]]"])
    }

    @Test func unclosedSyntaxIgnored() {
        #expect(!kinds("[[dangling and ==half\n").contains { if case .wikilink = $0 { true } else { false } })
        #expect(!kinds("==half\n").contains(.highlightMark))
    }
}

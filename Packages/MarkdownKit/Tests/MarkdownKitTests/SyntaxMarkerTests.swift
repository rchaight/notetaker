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

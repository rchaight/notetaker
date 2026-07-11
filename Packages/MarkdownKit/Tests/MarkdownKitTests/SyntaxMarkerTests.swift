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

    @Test func listBulletsHidden() {
        let found = markers("- first\n- second\n")
        #expect(found == ["- ", "- "])
    }

    @Test func orderedListNumbersHidden() {
        let found = markers("1. first\n2. second\n")
        #expect(found == ["1. ", "2. "])
    }

    @Test func taskItemHidesBulletKeepsCheckbox() {
        let text = "- [ ] call the dean\n"
        let found = markers(text)
        // The "- " bullet hides; "[ ]" stays visible (styled as UI).
        #expect(found.contains("- "))
        #expect(!found.contains { $0.contains("[") })
    }
}

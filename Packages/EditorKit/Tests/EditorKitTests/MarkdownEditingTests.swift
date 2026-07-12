@testable import EditorKit
import Foundation
import Testing

struct MarkdownEditingTests {
    private func run(_ command: EditorCommand, _ text: String, _ selection: NSRange) -> (String, NSRange)? {
        guard let result = MarkdownEditing.apply(command, to: text, selection: selection) else { return nil }
        let updated = (text as NSString).replacingCharacters(in: result.range, with: result.replacement)
        return (updated, result.selection)
    }

    @Test func boldWrapsSelection() throws {
        let (text, selection) = try #require(run(
            .wrap(prefix: "**", suffix: "**"),
            "make this bold",
            NSRange(location: 5, length: 4)
        ))
        #expect(text == "make **this** bold")
        #expect((text as NSString).substring(with: selection) == "this")
    }

    @Test func boldUnwrapsWhenAlreadyWrapped() throws {
        let (text, _) = try #require(run(
            .wrap(prefix: "**", suffix: "**"),
            "make **this** bold",
            NSRange(location: 5, length: 8)
        ))
        #expect(text == "make this bold")
    }

    @Test func emptySelectionInsertsMarkersWithCursorInside() throws {
        let (text, selection) = try #require(run(
            .wrap(prefix: "*", suffix: "*"),
            "note ",
            NSRange(location: 5, length: 0)
        ))
        #expect(text == "note **")
        #expect(selection == NSRange(location: 6, length: 0))
    }

    @Test func bulletTogglesOnAndOff() throws {
        let (on, _) = try #require(run(.toggleLinePrefix("- "), "first\nsecond", NSRange(location: 0, length: 12)))
        #expect(on == "- first\n- second")
        let (off, _) = try #require(run(
            .toggleLinePrefix("- "),
            on,
            NSRange(location: 0, length: (on as NSString).length)
        ))
        #expect(off == "first\nsecond")
    }

    @Test func todoReplacesBulletInsteadOfStacking() throws {
        let (text, _) = try #require(run(
            .toggleLinePrefix("- [ ] "),
            "- already a bullet",
            NSRange(location: 3, length: 0)
        ))
        #expect(text == "- [ ] already a bullet")
    }

    @Test func headingSetAndClear() throws {
        let (h2, _) = try #require(run(.setHeading(2), "plain line\n", NSRange(location: 2, length: 0)))
        #expect(h2 == "## plain line\n")
        let (swapped, _) = try #require(run(.setHeading(1), h2, NSRange(location: 3, length: 0)))
        #expect(swapped == "# plain line\n")
        let (body, _) = try #require(run(.setHeading(0), swapped, NSRange(location: 3, length: 0)))
        #expect(body == "plain line\n")
    }

    @Test func linkTemplateSelectsPlaceholder() throws {
        let (text, selection) = try #require(run(.link, "see docs now", NSRange(location: 4, length: 4)))
        #expect(text == "see [docs](url) now")
        #expect((text as NSString).substring(with: selection) == "url")
    }

    @Test func indentedLinesKeepIndent() throws {
        let (text, _) = try #require(run(.toggleLinePrefix("- [ ] "), "  nested item", NSRange(location: 4, length: 0)))
        #expect(text == "  - [ ] nested item")
    }
}

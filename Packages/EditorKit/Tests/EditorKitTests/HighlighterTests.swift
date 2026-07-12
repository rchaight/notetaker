@testable import EditorKit
import Foundation
import MarkdownKit
import Testing

#if canImport(AppKit)
    import AppKit

    private let monoTrait = NSFontDescriptor.SymbolicTraits.monoSpace
    private let boldTrait = NSFontDescriptor.SymbolicTraits.bold
#else
    import UIKit

    private let monoTrait = UIFontDescriptor.SymbolicTraits.traitMonoSpace
    private let boldTrait = UIFontDescriptor.SymbolicTraits.traitBold
#endif

@Suite(.serialized) @MainActor struct ThemeTests {
    let theme = MarkdownTheme.default

    @Test func headingFontsScaleDownByLevel() {
        let h1 = theme.headingFont(level: 1).pointSize
        let h3 = theme.headingFont(level: 3).pointSize
        let h6 = theme.headingFont(level: 6).pointSize
        #expect(h1 > h3)
        #expect(h3 > h6)
        #expect(h1 > theme.baseFont.pointSize)
    }

    @Test func codeUsesMonospacedFont() {
        let attributes = theme.attributes(for: .inlineCode)
        let font = attributes[.font] as? PlatformFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(monoTrait) ?? false)
    }

    @Test func everyKindHasDefinedAttributes() {
        let kinds: [MarkdownElementKind] = [
            .heading(level: 2), .strong, .emphasis, .strikethrough, .inlineCode,
            .codeBlock(language: "swift"), .link(destination: "https://x.y"),
            .blockQuote, .listItem, .taskCheckbox(checked: true),
            .taskCheckbox(checked: false), .thematicBreak, .table,
        ]
        for kind in kinds {
            _ = theme.attributes(for: kind) // must not crash; may be empty
        }
    }
}

@Suite(.serialized) @MainActor struct HighlighterTests {
    private func storage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        MarkdownHighlighter.highlight(storage)
        return storage
    }

    @Test func headingGetsHeadingFont() {
        let text = "# Big Title\n\nplain text\n"
        let styled = storage(text)
        let headingFont = styled.attribute(.font, at: 2, effectiveRange: nil) as? PlatformFont
        let bodyOffset = (text as NSString).range(of: "plain").location
        let bodyFont = styled.attribute(.font, at: bodyOffset, effectiveRange: nil) as? PlatformFont
        #expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? .infinity))
    }

    @Test func boldRunIsBold() {
        let text = "some **bold** text\n"
        let styled = storage(text)
        let offset = (text as NSString).range(of: "bold").location
        let font = styled.attribute(.font, at: offset, effectiveRange: nil) as? PlatformFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(boldTrait) ?? false)
    }

    @Test func checkedTaskIsStruckThrough() {
        let text = "- [x] done thing\n- [ ] open thing\n"
        let styled = storage(text)
        let doneOffset = (text as NSString).range(of: "done").location
        let openOffset = (text as NSString).range(of: "open").location
        let doneStrike = styled.attribute(.strikethroughStyle, at: doneOffset, effectiveRange: nil) as? Int
        let openStrike = styled.attribute(.strikethroughStyle, at: openOffset, effectiveRange: nil) as? Int
        #expect(doneStrike == NSUnderlineStyle.single.rawValue)
        #expect(openStrike == nil)
    }

    @Test func highlightingNeverMutatesCharacters() {
        let text = "# H\n\n- [ ] task **bold** `code`\n\n```swift\nlet a = 1\n```\n"
        let styled = storage(text)
        #expect(styled.string == text)
    }

    @Test func plainTextKeepsBaseAttributesOnly() {
        let text = "just words\n"
        let styled = storage(text)
        let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.pointSize == MarkdownTheme.default.baseFont.pointSize)
    }

    @Test func livePreviewHidesMarkersOffCursorLine() {
        let text = "**bold** here\n\n*second* line\n"
        let ns = text as NSString
        let storage = NSTextStorage(string: text)
        // Cursor on the first paragraph: its markers stay visible,
        // the second paragraph's markers collapse.
        let firstParagraph = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        MarkdownHighlighter.highlight(storage, hideMarkersOutside: firstParagraph)

        let firstMarkerFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect((firstMarkerFont?.pointSize ?? 0) > 1, "cursor-line markers must stay visible")

        let secondMarkerOffset = ns.range(of: "*second*").location
        let hiddenFont = storage.attribute(.font, at: secondMarkerOffset, effectiveRange: nil) as? PlatformFont
        #expect((hiddenFont?.pointSize ?? 1) < 1, "off-line markers must collapse")
        #expect(storage.string == text, "hiding must never mutate characters")
    }

    @Test func checkboxTokenIsStyledAndLinked() {
        let text = "- [ ] call the dean\n"
        let styled = storage(text)
        let tokenOffset = (text as NSString).range(of: "[ ]").location
        let link = styled.attribute(.link, at: tokenOffset, effectiveRange: nil) as? URL
        #expect(link != nil)
        #expect(link.flatMap(MarkdownHighlighter.toggleOffset(from:)) == tokenOffset)
        let font = styled.attribute(.font, at: tokenOffset, effectiveRange: nil) as? PlatformFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(monoTrait) ?? false)
        // The task text itself keeps the base font — only the token is special.
        let textOffset = (text as NSString).range(of: "call").location
        let textLink = styled.attribute(.link, at: textOffset, effectiveRange: nil)
        #expect(textLink == nil)
    }

    @Test func toggleURLRoundTrip() throws {
        let url = MarkdownHighlighter.toggleURL(at: 42)
        #expect(MarkdownHighlighter.toggleOffset(from: url) == 42)
        #expect(try MarkdownHighlighter.toggleOffset(from: #require(URL(string: "https://x.y/toggle/1"))) == nil)
    }

    @Test func sourceModeShowsAllMarkers() {
        let text = "**bold**\n\n*second*\n"
        let storage = NSTextStorage(string: text)
        MarkdownHighlighter.highlight(storage, hideMarkersOutside: nil)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect((font?.pointSize ?? 0) > 1)
    }
}

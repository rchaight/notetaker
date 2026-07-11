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

struct ThemeTests {
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

struct HighlighterTests {
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
}

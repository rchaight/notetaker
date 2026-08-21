#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif
@testable import EditorKit
import Foundation
import Testing

/// @MainActor like every AppKit-touching suite here: the fixtures carry
/// NSFont attribute values, and enumerating them on Swift Testing's
/// cooperative threads segfaulted intermittently (production always runs
/// the converter on the main thread — the paste path).
@MainActor
struct RichPasteTests {
    // MARK: - Fixture builders

    private func font(size: CGFloat = 13) -> PlatformFont {
        .systemFont(ofSize: size)
    }

    private func boldFont(size: CGFloat = 13) -> PlatformFont {
        .boldSystemFont(ofSize: size)
    }

    private func italicFont(size: CGFloat = 13) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size)
        #if canImport(AppKit)
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        #else
            if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return base
        #endif
    }

    private func monoFont(size: CGFloat = 13) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func run(_ text: String, _ attrs: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var full = attrs
        if full[.font] == nil {
            full[.font] = font()
        }
        return NSAttributedString(string: text, attributes: full)
    }

    private func document(_ parts: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font()]))
            }
            result.append(part)
        }
        return result
    }

    private func listParagraph(_ text: String, ordered: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
        return NSAttributedString(string: text, attributes: [.font: font(), .paragraphStyle: style])
    }

    private func quoteParagraph(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = 36
        style.firstLineHeadIndent = 36
        return NSAttributedString(string: text, attributes: [.font: font(), .paragraphStyle: style])
    }

    // MARK: - Converter: inline styling

    @Test func boldRunConverts() {
        let doc = document([run("Hello ") + run("world", [.font: boldFont()])])
        #expect(RichPaste.markdown(fromAttributed: doc) == "Hello **world**")
    }

    @Test func italicRunConverts() {
        let doc = run("Hello ") + run("world", [.font: italicFont()])
        #expect(RichPaste.markdown(fromAttributed: doc) == "Hello *world*")
    }

    @Test func strikethroughRunConverts() {
        let doc = run("Hello ") + run("world", [.strikethroughStyle: 1])
        #expect(RichPaste.markdown(fromAttributed: doc) == "Hello ~~world~~")
    }

    @Test func linkRunConverts() throws {
        let doc = try run("Check ") + run("this page", [.link: #require(URL(string: "https://example.com"))])
        #expect(RichPaste.markdown(fromAttributed: doc) == "Check [this page](https://example.com)")
    }

    @Test func inlineCodeRunConverts() {
        let doc = run("Use ") + run("let x = 1", [.font: monoFont()]) + run(" in code")
        #expect(RichPaste.markdown(fromAttributed: doc) == "Use `let x = 1` in code")
    }

    // MARK: - Converter: block structure

    @Test func headingFontSizeTierConverts() {
        let doc = document([
            run("Title", [.font: font(size: 21)]),
            run("Body text"),
        ])
        #expect(RichPaste.markdown(fromAttributed: doc) == "# Title\n\nBody text")
    }

    @Test func bulletListConverts() {
        let doc = document([
            listParagraph("First item", ordered: false),
            listParagraph("Second item", ordered: false),
        ])
        #expect(RichPaste.markdown(fromAttributed: doc) == "- First item\n- Second item")
    }

    @Test func numberedListConverts() {
        let doc = document([
            listParagraph("First item", ordered: true),
            listParagraph("Second item", ordered: true),
        ])
        #expect(RichPaste.markdown(fromAttributed: doc) == "1. First item\n2. Second item")
    }

    @Test func codeBlockParagraphConverts() {
        let doc = run("let total = a + b", [.font: monoFont()])
        #expect(RichPaste.markdown(fromAttributed: doc) == "```\nlet total = a + b\n```")
    }

    @Test func blockquoteConverts() {
        let doc = quoteParagraph("A quoted remark")
        #expect(RichPaste.markdown(fromAttributed: doc) == "> A quoted remark")
    }

    @Test func unknownStylingNeverDropsContent() {
        // A background highlight has no markdown equivalent — the text
        // must survive unstyled rather than vanish.
        let doc = run("Highlighted but plain text", [.backgroundColor: PlatformColor.yellow])
        #expect(RichPaste.markdown(fromAttributed: doc) == "Highlighted but plain text")
    }

    // MARK: - isProbablyMarkdown

    @Test func fencedCodeIsMarkdown() {
        #expect(RichPaste.isProbablyMarkdown("```\nlet x = 1\n```"))
    }

    @Test func twoHeadingsAreMarkdown() {
        #expect(RichPaste.isProbablyMarkdown("# Title\n## Subtitle\nSome body text"))
    }

    @Test func inlineLinkIsMarkdown() {
        #expect(RichPaste.isProbablyMarkdown("Check out [my site](https://example.com) today"))
    }

    @Test func plainProseIsNotMarkdown() {
        #expect(!RichPaste.isProbablyMarkdown("Hey, just wanted to say hi - and see how you're doing today."))
    }

    @Test func singleBulletyLineAloneIsNotMarkdown() {
        #expect(!RichPaste.isProbablyMarkdown("- one lonely line that isn't really a list"))
    }

    @Test func emptyPasteIsNotMarkdown() {
        #expect(!RichPaste.isProbablyMarkdown(""))
    }

    // MARK: - linkWrapping

    @Test func urlOverSelectionWraps() {
        #expect(RichPaste
            .linkWrapping(selection: "my site", pasted: "https://example.com") == "[my site](https://example.com)")
    }

    @Test func urlOverUrlDoesNotWrap() {
        #expect(RichPaste.linkWrapping(selection: "https://other.com", pasted: "https://example.com") == nil)
    }

    @Test func nonUrlPasteDoesNotWrap() {
        #expect(RichPaste.linkWrapping(selection: "my site", pasted: "just some text") == nil)
    }

    @Test func emptySelectionDoesNotWrap() {
        #expect(RichPaste.linkWrapping(selection: "", pasted: "https://example.com") == nil)
    }
}

private func + (lhs: NSAttributedString, rhs: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: lhs)
    result.append(rhs)
    return result
}

#if canImport(AppKit)
    /// Regression for the blank-note bug: the factory-then-swap
    /// construction left the layout manager rendering into a detached
    /// stock view. These assert the factory's stack is wired to THIS view
    /// end to end — storage sync AND layout production.
    @MainActor
    struct MarkdownTextViewFactoryTests {
        @Test func factoryBuildsARenderableTextKit2Stack() throws {
            let view = MarkdownTextView.makeTextKit2()
            let layoutManager = try #require(view.textLayoutManager)
            let contentStorage = try #require(view.textContentStorage)
            view.string = "# Hello\n\nWorld"
            #expect(contentStorage.textStorage?.string == "# Hello\n\nWorld")
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            var fragments = 0
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location
            ) { _ in
                fragments += 1
                return true
            }
            #expect(fragments > 0)
            #expect(layoutManager.textContainer === view.textContainer)
        }
    }
#endif

#if canImport(AppKit)
    import AppKit
#endif
@testable import EditorKit
import Foundation
import MarkdownKit
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

struct ListTypingTests {
    private func applyNewline(_ text: String, cursor: Int) -> (String, NSRange)? {
        guard let edit = MarkdownEditing.newlineContinuation(in: text, selection: NSRange(location: cursor, length: 0))
        else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    @Test func returnContinuesBullet() throws {
        let (text, selection) = try #require(applyNewline("- first", cursor: 7))
        #expect(text == "- first\n- ")
        #expect(selection.location == 10)
    }

    @Test func returnContinuesNumberIncremented() throws {
        let (text, _) = try #require(applyNewline("3. third", cursor: 8))
        #expect(text == "3. third\n4. ")
    }

    @Test func returnContinuesTodoUnchecked() throws {
        let (text, _) = try #require(applyNewline("- [x] done thing", cursor: 16))
        #expect(text == "- [x] done thing\n- [ ] ")
    }

    @Test func returnOnEmptyItemEndsList() throws {
        let full = "- item\n- "
        let (text, selection) = try #require(applyNewline(full, cursor: 9))
        #expect(text == "- item\n")
        #expect(selection.location == 7)
    }

    @Test func returnOnPlainLineIsDefault() {
        #expect(MarkdownEditing
            .newlineContinuation(in: "plain text", selection: NSRange(location: 5, length: 0)) == nil)
    }

    @Test func nestedItemKeepsIndentOnContinue() throws {
        let (text, _) = try #require(applyNewline("  - nested", cursor: 10))
        #expect(text == "  - nested\n  - ")
    }

    @Test func tabIndentsAndShiftTabOutdents() throws {
        let edit = try #require(MarkdownEditing.indentListItems(
            in: "- one\n- two", selection: NSRange(location: 0, length: 11), outdent: false
        ))
        let indented = ("- one\n- two" as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(indented == "  - one\n  - two")

        let back = try #require(MarkdownEditing.indentListItems(
            in: indented, selection: NSRange(location: 0, length: (indented as NSString).length), outdent: true
        ))
        let outdented = (indented as NSString).replacingCharacters(in: back.range, with: back.replacement)
        #expect(outdented == "- one\n- two")
    }

    @Test func tabOnPlainTextIsDefault() {
        #expect(MarkdownEditing.indentListItems(
            in: "no list here", selection: NSRange(location: 3, length: 0), outdent: false
        ) == nil)
    }
}

struct GlyphSubstitutionTests {
    private func display(_ line: String) -> String? {
        ListGlyphSubstitution.substituted(paragraph: NSAttributedString(string: line))?.string
    }

    @Test func swapsAreEqualLength() throws {
        for (line, expectedGlyph) in [
            ("- [ ] task", "○"), ("- [x] done", "●"), ("- bullet", "•"), ("* star", "•"),
        ] {
            let swapped = try #require(display(line))
            #expect((swapped as NSString).length == (line as NSString).length,
                    "display offsets must match backing store for: \(line)")
            #expect(swapped.contains(expectedGlyph))
        }
    }

    @Test func indentIsPreserved() throws {
        let swapped = try #require(display("    - nested"))
        #expect(swapped.hasPrefix("    "))
        #expect(swapped.contains("•"))
    }

    @Test func numbersAndPlainLinesUntouched() {
        #expect(display("1. numbered") == nil)
        #expect(display("plain text") == nil)
    }

    @Test func attributesSurviveSwap() throws {
        let source = NSMutableAttributedString(string: "- [ ] task")
        try source.addAttribute(
            .link,
            value: #require(URL(string: "notetaker-task://toggle/2")),
            range: NSRange(location: 2, length: 3)
        )
        let swapped = try #require(ListGlyphSubstitution.substituted(paragraph: source))
        let link = swapped.attribute(.link, at: 2, effectiveRange: nil)
        #expect(link != nil, "checkbox click-through must survive substitution")
    }

    @Test func glyphSitsOnTheClickableTokenRange() throws {
        // The toggle link covers "[ ]" (offsets 2–4 of "- [ ]"): the glyph
        // must be the FIRST character of that range or the link's styling
        // lands on padding beside an unclickable box.
        for (line, glyph) in [("- [ ] t", "○"), ("- [x] t", "●")] {
            let swapped = try #require(display(line))
            let index = try #require(swapped.firstIndex(of: Character(glyph)))
            #expect(swapped.distance(from: swapped.startIndex, to: index) == 2)
        }
    }
}

@MainActor struct ThemeTokenTests {
    @Test func surfaceTokensResolveDistinctAppearances() throws {
        let theme = MarkdownTheme.default
        #if canImport(AppKit)
            var light = NSColor.white, dark = NSColor.white
            try #require(NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                light = theme.editorBackground.usingColorSpace(.sRGB) ?? .white
            })
            try #require(NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                dark = theme.editorBackground.usingColorSpace(.sRGB) ?? .white
            })
            #expect(light != dark, "editor surface must adapt to appearance")
            #expect(dark.brightnessComponent > 0.02, "dark surface must stay off pure black")
        #endif
    }

    @Test func accentDerivedTokensShareHue() {
        let theme = MarkdownTheme.default
        #expect(theme.selectionBackground.cgColor.alpha < 1.0)
        #expect(theme.quoteAccent.cgColor.alpha < 1.0)
    }
}

@MainActor struct FocusDimTests {
    @Test func dimsOutsideFocusOnly() {
        let storage = NSTextStorage(string: "alpha\n\nbeta\n\ngamma\n")
        let theme = MarkdownTheme.default
        let focus = (storage.string as NSString).range(of: "beta\n")
        MarkdownHighlighter.highlight(storage, theme: theme, dimOutside: focus)
        let dim = theme.focusDimColor
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor == dim)
        #expect(storage.attribute(.foregroundColor, at: focus.location, effectiveRange: nil) as? PlatformColor == theme
            .textColor)
        #expect(storage.attribute(
            .foregroundColor,
            at: focus.location + focus.length + 2,
            effectiveRange: nil
        ) as? PlatformColor == dim)
    }

    @Test func hiddenMarkersStayClearUnderDim() {
        let storage = NSTextStorage(string: "**bold**\n\ncursor here\n")
        let theme = MarkdownTheme.default
        let focus = (storage.string as NSString).range(of: "cursor here\n")
        MarkdownHighlighter.highlight(
            storage, theme: theme, hideMarkersOutside: focus, dimOutside: focus
        )
        let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor
        #expect(markerColor == .clear, "marker hiding must win over focus dim")
    }
}

struct BlockquoteDetectionTests {
    @Test func detectsQuoteParagraphs() {
        #expect(BlockquoteDetection.isQuoteParagraph("> quoted"))
        #expect(BlockquoteDetection.isQuoteParagraph("   > indented quote"))
        #expect(BlockquoteDetection.isQuoteParagraph("> > nested"))
        #expect(!BlockquoteDetection.isQuoteParagraph("    > four spaces is code"))
        #expect(!BlockquoteDetection.isQuoteParagraph("plain"))
        #expect(!BlockquoteDetection.isQuoteParagraph(""))
    }
}

struct ThematicBreakDetectionTests {
    @Test func detectsRules() {
        #expect(ThematicBreakDetection.isRuleParagraph("---"))
        #expect(ThematicBreakDetection.isRuleParagraph("***\n"))
        #expect(ThematicBreakDetection.isRuleParagraph("___"))
        #expect(ThematicBreakDetection.isRuleParagraph("- - -"))
        #expect(ThematicBreakDetection.isRuleParagraph("  ----------"))
        #expect(!ThematicBreakDetection.isRuleParagraph("--"))
        #expect(!ThematicBreakDetection.isRuleParagraph("--- text"))
        #expect(!ThematicBreakDetection.isRuleParagraph("    ---"))
        #expect(!ThematicBreakDetection.isRuleParagraph("-*-"))
    }
}

@MainActor struct RuleHidingTests {
    @Test func dashesGoClearOffCursorAtFullSize() {
        let storage = NSTextStorage(string: "above\n\n---\n\nbelow\n")
        let theme = MarkdownTheme.default
        let cursor = NSRange(location: 0, length: 6)
        MarkdownHighlighter.highlight(storage, theme: theme, hideMarkersOutside: cursor)
        let dashAt = (storage.string as NSString).range(of: "---").location
        let color = storage.attribute(.foregroundColor, at: dashAt, effectiveRange: nil) as? PlatformColor
        let font = storage.attribute(.font, at: dashAt, effectiveRange: nil) as? PlatformFont
        #expect(color == .clear)
        #expect((font?.pointSize ?? 0) > 1, "row height must not collapse")
    }
}

struct ImageThumbnailTests {
    @Test func standaloneImageDetection() {
        #expect(ImageThumbnails.standaloneImageSource("![alt](pic.png)") == "pic.png")
        #expect(ImageThumbnails.standaloneImageSource("  ![](sub/photo.jpg)\n") == "sub/photo.jpg")
        #expect(ImageThumbnails.standaloneImageSource("text ![alt](pic.png)") == nil)
        #expect(ImageThumbnails.standaloneImageSource("![alt](pic.png) tail") == nil)
        #expect(ImageThumbnails.standaloneImageSource("![alt]()") == nil)
        #expect(ImageThumbnails.standaloneImageSource("[link](url)") == nil)
    }

    @Test func localResolutionOnly() {
        let base = URL(fileURLWithPath: "/vault/Notes")
        #expect(ImageThumbnails.resolveLocalURL("img.png", base: base)?.path == "/vault/Notes/img.png")
        #expect(ImageThumbnails.resolveLocalURL("../Assets/i.png", base: base)?.path == "/vault/Assets/i.png")
        #expect(ImageThumbnails.resolveLocalURL("/abs/i.png", base: nil)?.path == "/abs/i.png")
        #expect(ImageThumbnails.resolveLocalURL("https://example.com/i.png", base: base) == nil)
        #expect(ImageThumbnails.resolveLocalURL("rel.png", base: nil) == nil)
    }
}

@MainActor struct ImageSpacingTests {
    @Test func standaloneImageLineReservesThumbnailRoom() {
        let storage = NSTextStorage(string: "before\n\n![shot](s.png)\n\nafter\n")
        MarkdownHighlighter.highlight(storage)
        let at = (storage.string as NSString).range(of: "![shot]").location
        let style = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.paragraphSpacing ?? 0) >= MarkdownTheme.imageThumbnailHeight)
        let before = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect((before?.paragraphSpacing ?? 0) < MarkdownTheme.imageThumbnailHeight)
    }
}

struct CodeCardRegionTests {
    private func regions(_ text: String) -> [CodeCardRegions.Region] {
        CodeCardRegions.regions(in: text, styled: MarkdownStyler.styleRanges(in: text))
    }

    @Test func fencedBlockYieldsContentBetweenFences() {
        let text = "before\n```swift\nlet x = 1\nlet y = 2\n```\nafter\n"
        let found = regions(text)
        #expect(found.count == 1)
        let content = (text as NSString).substring(with: found[0].range)
        #expect(content == "let x = 1\nlet y = 2\n")
        #expect(found[0].language == "swift")
    }

    @Test func tildeFenceAndNoLanguage() {
        let text = "~~~\ncode\n~~~\n"
        let found = regions(text)
        #expect(found.count == 1)
        #expect((text as NSString).substring(with: found[0].range) == "code\n")
        #expect(found[0].language == nil)
    }

    @Test func unclosedFenceStillCards() {
        let text = "```py\nx = 1\n"
        let found = regions(text)
        #expect(found.count == 1)
        #expect((text as NSString).substring(with: found[0].range).hasPrefix("x = 1"))
    }

    @Test func indentedCodeBlockHasNoCard() {
        #expect(regions("    indented code\n").isEmpty)
    }

    @Test func listSyntaxInsideCodeIsInsideARegion() {
        let text = "```\n- not a bullet\n```\n"
        let found = regions(text)
        let bullet = (text as NSString).range(of: "- not")
        #expect(found.count == 1)
        #expect(NSIntersectionRange(found[0].range, bullet).length > 0,
                "glyph substitution guard depends on this containment")
    }
}

struct TableGridTests {
    private let table = """
    intro

    | Name | Role |
    | ---- | :--: |
    | Ada  | Math |
    | Grace | Code |

    outro
    """

    private func regions(_ text: String) -> [TableGrid.Region] {
        TableGrid.regions(in: text, styled: MarkdownStyler.styleRanges(in: text))
    }

    @Test func parsesRowsCellsAndSeparator() {
        let found = regions(table)
        #expect(found.count == 1)
        let rows = found[0].rows
        #expect(rows.count == 4)
        #expect(rows[0].cells == ["Name", "Role"])
        #expect(rows[1].isSeparator)
        #expect(rows[3].cells == ["Grace", "Code"])
        #expect(found[0].columnCount == 2)
    }

    @Test func rowRangesSliceTheSource() {
        let found = regions(table)
        let ns = table as NSString
        #expect(ns.substring(with: found[0].rows[2].range).contains("Ada"))
    }

    @Test func columnLayoutIsMonotonicWithPadding() {
        let found = regions(table)
        let layout = TableGrid.columnLayout(
            for: found[0],
            headerFont: MarkdownTheme.default.tableHeaderFont,
            bodyFont: MarkdownTheme.default.baseFont
        )
        #expect(layout.count == 2)
        #expect(layout[1].x == layout[0].x + layout[0].width)
        #expect(layout.allSatisfy { $0.width >= 44 })
    }

    @Test func plainPipeTextIsNotATable() {
        #expect(regions("a | b without header row\n").isEmpty)
    }
}

@MainActor struct TableHidingTests {
    @Test func tableClearsOffCursorRevealsOnCursor() {
        let text = "cursor\n\n| a | b |\n| - | - |\n| 1 | 2 |\n"
        let storage = NSTextStorage(string: text)
        let cursorOutside = NSRange(location: 0, length: 7)
        MarkdownHighlighter.highlight(storage, hideMarkersOutside: cursorOutside)
        let pipeAt = (text as NSString).range(of: "| a").location
        #expect(storage.attribute(.foregroundColor, at: pipeAt, effectiveRange: nil) as? PlatformColor == .clear)

        let cursorInside = (text as NSString).range(of: "| a | b |\n")
        MarkdownHighlighter.highlight(storage, hideMarkersOutside: cursorInside)
        #expect(storage.attribute(.foregroundColor, at: pipeAt, effectiveRange: nil) as? PlatformColor != .clear)
    }
}

struct InsertBlockTests {
    private func apply(_ text: String, cursor: Int, block: String, offset: Int? = nil) -> (String, NSRange)? {
        guard let edit = MarkdownEditing.apply(
            .insertBlock(block, cursorOffset: offset),
            to: text, selection: NSRange(location: cursor, length: 0)
        ) else { return nil }
        let ns = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (ns, edit.selection)
    }

    @Test func insertsAfterNonEmptyParagraph() throws {
        let (result, _) = try #require(apply("some text\nmore\n", cursor: 3, block: "---"))
        #expect(result == "some text\n\n---\nmore\n")
    }

    @Test func replacesEmptyLineInPlace() throws {
        let (result, _) = try #require(apply("above\n\nbelow\n", cursor: 6, block: "---"))
        #expect(result == "above\n---\n\nbelow\n")
    }

    @Test func atEndOfFileWithoutTrailingNewline() throws {
        let (result, _) = try #require(apply("tail", cursor: 4, block: "---"))
        #expect(result == "tail\n\n---\n")
    }

    @Test func cursorOffsetLandsInsideBlock() throws {
        let table = "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |"
        let (result, selection) = try #require(apply("intro\n", cursor: 2, block: table, offset: 2))
        let ns = result as NSString
        #expect(ns.substring(with: NSRange(location: selection.location, length: 8)) == "Column 1")
    }
}

struct AutocompleteTests {
    private func match(_ text: String, cursorAfter marker: String) -> AutocompleteContext.Match? {
        let location = (text as NSString).range(of: marker).location + (marker as NSString).length
        return AutocompleteContext.match(in: text, cursor: location)
    }

    @Test func tagContexts() {
        #expect(match("note #pro", cursorAfter: "#pro") ==
            .init(kind: .tag, query: "pro"))
        #expect(match("x #project/al", cursorAfter: "/al") ==
            .init(kind: .tag, query: "project/al"))
        // A bare "#" must NOT trigger — it's also the heading marker.
        #expect(match("bare # here", cursorAfter: "bare #") == nil)
        #expect(match("# ", cursorAfter: "#") == nil)
        #expect(match("## Sec", cursorAfter: "##") == nil)
        #expect(match("not#atag", cursorAfter: "not#a") == nil)
        #expect(match("after space #tag done", cursorAfter: "done") == nil)
    }

    @Test func wikilinkContexts() {
        #expect(match("see [[Proj", cursorAfter: "[[Proj") ==
            .init(kind: .wikilink, query: "Proj"))
        #expect(match("see [[Big Plan", cursorAfter: "Plan") ==
            .init(kind: .wikilink, query: "Big Plan"))
        #expect(match("closed [[Done]] after", cursorAfter: "after") == nil)
    }

    @Test func completionAlignmentToPartialWord() {
        // Query "project/al", system partial word "al": candidates trim to
        // the partial's start and full-match candidates drop out.
        let out = AutocompleteContext.completionStrings(
            query: "project/al", partialLength: 2,
            candidates: ["project/alpha", "project/beta", "home"]
        )
        #expect(out == ["alpha"])
        let links = AutocompleteContext.completionStrings(
            query: "Pro", partialLength: 3,
            candidates: ["Project Plan", "Notes"], appending: "]]"
        )
        #expect(links == ["Project Plan]]"])
    }
}

@MainActor struct FrontmatterHidingTests {
    @Test func frontmatterCollapsesOffCursorRevealsOnCursor() {
        let text = "---\nfavorite: true\n---\n# Body\ntext\n"
        let storage = NSTextStorage(string: text)
        let bodyStart = (text as NSString).range(of: "# Body").location
        MarkdownHighlighter.highlight(
            storage, hideMarkersOutside: NSRange(location: bodyStart, length: 6)
        )
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect((font?.pointSize ?? 10) < 1, "frontmatter must collapse off-cursor")

        MarkdownHighlighter.highlight(
            storage, hideMarkersOutside: NSRange(location: 0, length: 4)
        )
        let revealed = storage.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect((revealed?.pointSize ?? 0) > 1, "cursor inside reveals the block")
    }
}

struct SubstringCompletionTests {
    @Test func newTagOffersSubstringNearMisses() {
        let out = AutocompleteContext.completionStrings(
            query: "notes", partialLength: 5,
            candidates: ["meeting-notes", "notes-archive", "budget"],
            substringMatch: true
        )
        #expect(out.contains("meeting-notes"))
        #expect(out.contains { $0.hasSuffix("-archive") || $0 == "notes-archive" })
        #expect(!out.contains("budget"))
    }
}

import Foundation
import MarkdownKit
@testable import ReadingKit
import Testing

// MARK: - Helpers

private func blocks(_ source: String) -> [ReadingBlock] {
    ReadingDocument.build(from: source)
}

/// Flattens every inline in the document, including the ones inside quotes,
/// list items and table cells.
private func allInlines(_ blocks: [ReadingBlock]) -> [ReadingInline] {
    var found: [ReadingInline] = []
    func descend(_ inlines: [ReadingInline]) {
        for inline in inlines {
            found.append(inline)
            switch inline {
            case let .strong(children), let .emphasis(children),
                 let .strikethrough(children), let .highlight(children):
                descend(children)
            case let .link(_, children):
                descend(children)
            default:
                continue
            }
        }
    }
    func walk(_ blocks: [ReadingBlock]) {
        for block in blocks {
            switch block.kind {
            case let .heading(_, inlines), let .paragraph(inlines):
                descend(inlines)
            case let .list(_, _, items):
                for item in items {
                    descend(item.inlines)
                    walk(item.children)
                }
            case let .blockquote(inner):
                walk(inner)
            case let .table(header, rows, _):
                for cell in header {
                    descend(cell.inlines)
                }
                for row in rows {
                    for cell in row {
                        descend(cell.inlines)
                    }
                }
            default:
                continue
            }
        }
    }
    walk(blocks)
    return found
}

/// The inline case's name, so a test can assert on shape without a wall of
/// wrapped `if case` expressions.
private func caseName(_ inline: ReadingInline) -> String {
    switch inline {
    case .text: "text"
    case .strong: "strong"
    case .emphasis: "emphasis"
    case .strikethrough: "strikethrough"
    case .code: "code"
    case .link: "link"
    case .image: "image"
    case .wikilink: "wikilink"
    case .highlight: "highlight"
    case .tag: "tag"
    case .mention: "mention"
    case .kindToken: "kindToken"
    case .lineBreak: "lineBreak"
    case .softBreak: "softBreak"
    }
}

/// Every inline reduced to "case:payload" — what most shape assertions want.
private func tokenNames(_ inlines: [ReadingInline]) -> [String] {
    inlines.map { inline in
        switch inline {
        case let .code(code): "code:\(code)"
        case let .tag(name): "tag:\(name)"
        case let .mention(name): "mention:\(name)"
        case let .kindToken(kind): "kindToken:\(kind)"
        case let .wikilink(target): "wikilink:\(target)"
        default: caseName(inline)
        }
    }
}

/// The extended tokens Reading mode found, as comparable strings.
private func extendedTokens(_ blocks: [ReadingBlock]) -> Set<String> {
    Set(allInlines(blocks).compactMap { inline in
        switch inline {
        case let .wikilink(target): "wikilink:\(target)"
        case let .tag(name): "tag:\(name)"
        case let .mention(name): "mention:\(name)"
        case let .kindToken(kind): "kind:\(kind)"
        case let .highlight(children): "highlight:\(ReadingInlineText.plainText(children))"
        default: nil
        }
    })
}

/// The same tokens as the EDITOR sees them, straight out of MarkdownStyler.
private func stylerTokens(_ body: String) -> Set<String> {
    let ns = body as NSString
    return Set(MarkdownStyler.styleRanges(in: body).compactMap { styled in
        switch styled.kind {
        case let .wikilink(target): "wikilink:\(target)"
        case let .tag(name): "tag:\(name)"
        case let .mention(name): "mention:\(name)"
        case let .kindToken(kind): "kind:\(kind)"
        case .highlightMark:
            "highlight:" + ns.substring(with: NSRange(
                location: styled.range.location + 2, length: styled.range.length - 4
            ))
        default: nil
        }
    })
}

// MARK: - Block model

struct ReadingBlockModelTests {
    @Test func headingCarriesLevelAndLine() {
        let model = blocks("intro\n\n## Second level\n")
        #expect(model.count == 2)
        guard case let .heading(level, inlines) = model[1].kind else {
            Issue.record("expected a heading, got \(model[1].kind)")
            return
        }
        #expect(level == 2)
        #expect(ReadingInlineText.plainText(inlines) == "Second level")
        #expect(model[1].firstLine == 2)
    }

    @Test func paragraphKeepsInlineFormatting() {
        let model = blocks("plain **bold** and *italic* and `code` and ~~gone~~\n")
        guard case let .paragraph(inlines) = model[0].kind else {
            Issue.record("expected a paragraph")
            return
        }
        let names = tokenNames(inlines)
        #expect(names.contains("strong"))
        #expect(names.contains("emphasis"))
        #expect(names.contains("code:code"))
        #expect(names.contains("strikethrough"))
    }

    @Test func nestedListsBecomeChildBlocks() {
        let model = blocks("- outer\n  - inner\n    - deepest\n")
        guard case let .list(ordered, _, items) = model[0].kind else {
            Issue.record("expected a list")
            return
        }
        #expect(ordered == false)
        #expect(items.count == 1)
        #expect(ReadingInlineText.plainText(items[0].inlines) == "outer")
        guard case let .list(_, _, inner) = items[0].children.first?.kind else {
            Issue.record("expected a nested list under the outer item")
            return
        }
        #expect(ReadingInlineText.plainText(inner[0].inlines) == "inner")
        #expect(inner[0].children.count == 1, "three levels of nesting survive")
        #expect(inner[0].sourceLine == 1)
    }

    @Test func orderedListKeepsItsStartNumber() {
        let model = blocks("3. three\n4. four\n")
        guard case let .list(ordered, start, items) = model[0].kind else {
            Issue.record("expected a list")
            return
        }
        #expect(ordered)
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test func blockquoteHoldsItsOwnBlocks() {
        let model = blocks("> quoted words\n>\n> - a bullet\n")
        guard case let .blockquote(inner) = model[0].kind else {
            Issue.record("expected a blockquote")
            return
        }
        #expect(inner.count == 2)
        if case .paragraph = inner[0].kind {} else {
            Issue.record("first quoted block should be a paragraph")
        }
        if case .list = inner[1].kind {} else {
            Issue.record("second quoted block should be a list")
        }
    }

    @Test func codeBlockKeepsLanguageAndBody() {
        let model = blocks("```swift\nlet x = 1\n```\n")
        guard case let .codeBlock(language, text) = model[0].kind else {
            Issue.record("expected a code block")
            return
        }
        #expect(language == "swift")
        #expect(text == "let x = 1")
    }

    @Test func tableCarriesHeaderRowsAndAlignments() {
        let model = blocks("| A | B | C |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |\n")
        guard case let .table(header, rows, alignments) = model[0].kind else {
            Issue.record("expected a table")
            return
        }
        #expect(header.map { ReadingInlineText.plainText($0.inlines) } == ["A", "B", "C"])
        #expect(rows.count == 1)
        #expect(rows[0].map { ReadingInlineText.plainText($0.inlines) } == ["1", "2", "3"])
        #expect(alignments == [.leading, .center, .trailing])
    }

    @Test func thematicBreakAndStandaloneImage() {
        let model = blocks("---\n\n![a picture](images/pic.png)\n")
        // A leading "---" with no closing fence is a rule, not frontmatter.
        #expect(model.contains { $0.kind == .thematicBreak })
        guard let image = model.compactMap({ block -> (String, String)? in
            if case let .image(source, alt) = block.kind {
                (source, alt)
            } else {
                nil
            }
        }).first else {
            Issue.record("expected a standalone image block")
            return
        }
        #expect(image.0 == "images/pic.png")
        #expect(image.1 == "a picture")
    }

    @Test func htmlBlockFallsBackToLiteralText() {
        let model = blocks("<div class=\"x\">raw</div>\n")
        guard case let .html(raw) = model[0].kind else {
            Issue.record("expected an html block, got \(model[0].kind)")
            return
        }
        #expect(raw.contains("<div"))
    }

    @Test func frontmatterBecomesACardAheadOfTheBody() {
        let model = blocks("---\ntitle: Big Plan\nstatus: active\n---\n# Heading\n")
        guard case let .frontmatter(pairs) = model[0].kind else {
            Issue.record("expected a frontmatter card")
            return
        }
        #expect(pairs.map(\.key) == ["status", "title"], "keys render in stable sorted order")
        #expect(pairs.first { $0.key == "title" }?.value == "Big Plan")
        #expect(model[0].firstLine == 0)
        #expect(model[0].lastLine == 3)
        #expect(model[1].firstLine == 4, "the body starts on the line after the fence")
    }

    @Test func lockedNoteRendersOnePlaceholderNotCiphertext() {
        let ciphertext = "T25lIGxvbmcgYmFzZTY0IGJsb2Igb2YgY2lwaGVydGV4dCB0aGF0IG11c3QgbmV2ZXIgcmVuZGVy"
        let model = blocks("---\nlocked: true\nsalt: YWJjZA==\nrounds: 210000\n---\n\(ciphertext)\n")
        #expect(model.count == 1)
        #expect(model[0].kind == .locked)
        // Nothing from the body may reach the renderer.
        #expect(!ReadingInlineText.plainText(allInlines(model)).contains("base64"))
        #expect(allInlines(model).isEmpty)
    }
}

// MARK: - Tasks

struct ReadingTaskTests {
    @Test func taskItemRoutesTokensToMetadataNotRawText() {
        let model = blocks("- [ ] buy milk >2026-07-15 !p1 #errand @robert ?discuss\n")
        guard case let .list(_, _, items) = model[0].kind, let item = items.first else {
            Issue.record("expected a task list")
            return
        }
        #expect(item.checked == false)
        let task = try? #require(item.task)
        #expect(task?.dueDate == "2026-07-15")
        #expect(task?.priority == 1)
        #expect(task?.assignee == "robert")
        #expect(task?.kind == "discuss")
        #expect(task?.labels == ["errand"])

        let rendered = ReadingInlineText.plainText(item.inlines)
        #expect(!rendered.contains(">2026-07-15"), "due token renders as a chip, never raw")
        #expect(!rendered.contains("!p1"), "priority token renders as a chip, never raw")
        #expect(!rendered.contains("@robert"), "assignee token renders as a chip, never raw")
        #expect(!rendered.contains("?discuss"), "kind token renders as a chip, never raw")
        // #tags stay in cleanText by design — they read as content, and the
        // editor shows them in place too.
        #expect(tokenNames(item.inlines).contains("tag:errand"))
        #expect(rendered.hasPrefix("buy milk"))
    }

    @Test func checkedTaskAndRecurrenceSurvive() {
        let model = blocks("- [x] water plants &every 2 weeks ✅2026-07-14\n")
        guard case let .list(_, _, items) = model[0].kind, let item = items.first else {
            Issue.record("expected a task list")
            return
        }
        #expect(item.checked == true)
        #expect(item.task?.recurrence?.rawToken.contains("every 2 weeks") == true)
        #expect(item.task?.completedDay == "2026-07-14")
        #expect(ReadingInlineText.plainText(item.inlines) == "water plants")
    }

    @Test func taskSourceLineIsTheFileLineTheIndexUses() {
        let source = """
        ---
        title: Plan
        ---
        # Today

        - [ ] first task
        - [ ] second task
        """
        let model = blocks(source)
        let tasks = ReadingDocument.taskItems(in: model)
        #expect(tasks.map(\.sourceLine) == [5, 6])
        // The contract: the same 0-based FILE line NoteScanner reports, so
        // TaskRecord.line and ReadingListItem.sourceLine are interchangeable.
        let scanned = NoteScanner.tasks(in: source)
        #expect(scanned.map(\.line) == tasks.map(\.sourceLine))
    }

    @Test func nestedTaskItemsAreFoundAndAnchored() {
        let source = "- [ ] parent\n  - [x] child\n  - [ ] sibling\n"
        let tasks = ReadingDocument.taskItems(in: blocks(source))
        #expect(tasks.count == 3)
        #expect(tasks.map(\.sourceLine) == [0, 1, 2])
        #expect(tasks.map(\.checked) == [false, true, false])
        #expect(NoteScanner.tasks(in: source).map(\.line) == tasks.map(\.sourceLine))
    }

    /// Criterion 4, as far as a package test can reach: `sourceLine` +
    /// the raw line it points at are exactly the two arguments
    /// `VaultIndexService.toggle` hands `TaskLineToggler`, so a Reading-mode
    /// tap flips the right source line and leaves its neighbour byte-exact.
    /// The GRDB/app half (finding the TaskRecord) has no test target here.
    @Test func toggleThroughTheSourceLineFlipsThatLineOnly() {
        let source = "---\ntitle: T\n---\n# Heading\n\n- [ ] alpha\n- [ ] beta\n"
        let items = ReadingDocument.taskItems(in: blocks(source))
        #expect(items.map(\.sourceLine) == [5, 6])

        let beta = items[1]
        let raw = splitLines(source)[beta.sourceLine]
        let result = TaskLineToggler.toggle(
            contents: source, anchorLine: beta.sourceLine,
            expectedRawLine: raw, completionDay: "2026-09-15"
        )
        #expect(result?.nowChecked == true)
        #expect(result?.line == 6)

        let after = ReadingDocument.taskItems(in: blocks(result?.contents ?? ""))
        #expect(after.map(\.checked) == [false, true])
        #expect(after[1].task?.completedDay == "2026-09-15")
        #expect(splitLines(result?.contents ?? "")[5] == "- [ ] alpha", "neighbour untouched")
    }

    @Test func plainBulletIsNotATask() {
        let model = blocks("- just a bullet\n")
        guard case let .list(_, _, items) = model[0].kind else {
            Issue.record("expected a list")
            return
        }
        #expect(items[0].checked == nil)
        #expect(items[0].task == nil)
        #expect(ReadingDocument.taskItems(in: model).isEmpty)
    }
}

// MARK: - Extended-syntax parity

struct ReadingExtendedSyntaxTests {
    /// No task lines here on purpose: task items route @person / ?kind into
    /// chips (they leave `cleanText`), so parity with the editor's raw-text
    /// scan is only meaningful on prose. `taskItemRoutesTokensToMetadata…`
    /// covers the task path.
    private static let fixture = """
    Prose with [[Wiki Link]] plus ==marked words== and #project/alpha.

    A line naming @robert and flagging ?waiting for later.

    - a bullet with [[Second Note]] and #urgent
    - another with ==emphasis== and @dana

    | Column | Notes |
    | --- | --- |
    | [[Table Link]] | #tabletag |

    > quoted with @casey and ?followup

    `inline [[not a link]] #nottag` stays literal, and so does:

    ```
    [[fenced]] #fenced @fenced ?discuss
    ```
    """

    @Test func detectionMatchesMarkdownStylerExactly() {
        let mine = extendedTokens(blocks(Self.fixture))
        let editor = stylerTokens(Self.fixture)
        #expect(mine == editor, "Reading mode and the editor must agree token for token")
        #expect(mine.contains("wikilink:Wiki Link"))
        #expect(mine.contains("tag:project/alpha"))
        #expect(mine.contains("mention:robert"))
        #expect(mine.contains("kind:waiting"))
        #expect(mine.contains("highlight:marked words"))
    }

    @Test func tokensInsideCodeStayLiteral() {
        let mine = extendedTokens(blocks(Self.fixture))
        #expect(!mine.contains("wikilink:not a link"), "inline code is literal text")
        #expect(!mine.contains("tag:nottag"))
        #expect(!mine.contains("wikilink:fenced"), "fenced code is literal text")
        #expect(!mine.contains("kind:discuss"))
    }

    @Test func wikilinkSurvivesCmarkSplittingTextAtBrackets() {
        // cmark hands literal "[[" back as separate text runs; the builder
        // merges adjacent runs before looking for tokens.
        let model = blocks("see [[A Note]] then [[B Note]] done\n")
        let targets = allInlines(model).compactMap { inline -> String? in
            if case let .wikilink(target) = inline {
                target
            } else {
                nil
            }
        }
        #expect(targets == ["A Note", "B Note"])
    }

    @Test func highlightKeepsTokensInsideIt() {
        let model = blocks("==hot #urgent== rest\n")
        let names = tokenNames(allInlines(model))
        #expect(names.contains("tag:urgent"))
        #expect(names.contains("highlight"))
    }

    @Test func wikilinkURLRoundTripsThroughTheTapScheme() {
        let url = try? #require(ReadingInlineText.url(forWikilink: "Weekly 1:1 / Robert"))
        #expect(url.flatMap(ReadingInlineText.wikilinkTarget) == "Weekly 1:1 / Robert")
        let http = try? #require(URL(string: "https://example.com"))
        #expect(http.flatMap(ReadingInlineText.wikilinkTarget) == nil)
    }
}

// MARK: - Position sync

struct ReadingPositionTests {
    private static let source = """
    # Title

    First paragraph.

    - [ ] a task
    - [ ] another

    ## Section

    Closing paragraph.
    """

    @Test func anchorLineFindsTheBlockContainingALine() {
        let model = blocks(Self.source)
        // Line 4 is the first task line; its block is the list starting there.
        #expect(ReadingDocument.anchorLine(for: 4, in: model) == 4)
        #expect(ReadingDocument.anchorLine(for: 5, in: model) == 4, "inside the same list block")
        #expect(ReadingDocument.anchorLine(for: 2, in: model) == 2)
        #expect(ReadingDocument.anchorLine(for: 7, in: model) == 7)
    }

    @Test func anchorLineFallsBackToThePrecedingBlockAndClamps() {
        let model = blocks(Self.source)
        // Line 1 is blank — no block owns it, so the heading above wins.
        #expect(ReadingDocument.anchorLine(for: 1, in: model) == 0)
        #expect(ReadingDocument.anchorLine(for: 9999, in: model) == model.last?.firstLine)
        #expect(ReadingDocument.anchorLine(for: 0, in: []) == nil)
    }

    @Test func liveToReadingToLiveRoundTripsTheSameParagraph() {
        // Live → Reading: the caret's UTF-16 offset becomes a file line,
        // which becomes a block anchor. Reading → Live: that block's line
        // becomes an offset again. The paragraph must not drift.
        let lines = ReadingSourceLines(Self.source)
        let model = blocks(Self.source)
        let caret = (Self.source as NSString).range(of: "another").location
        let caretLine = lines.line(forUTF16Offset: caret)
        #expect(caretLine == 5)

        let anchor = try? #require(ReadingDocument.anchorLine(for: caretLine, in: model))
        #expect(anchor == 4, "the list block containing the caret's line")

        let backToOffset = lines.utf16Offset(ofLine: anchor ?? 0)
        #expect(lines.line(forUTF16Offset: backToOffset) == 4)
        #expect((Self.source as NSString).substring(
            from: backToOffset
        ).hasPrefix("- [ ] a task"))
    }

    @Test func sourceLineMathSurvivesCRLF() {
        let text = "alpha\r\nbeta\r\ngamma"
        let lines = ReadingSourceLines(text)
        #expect(lines.lineCount == 3)
        #expect(lines.line(forUTF16Offset: 0) == 0)
        #expect(lines.line(forUTF16Offset: 8) == 1)
        // "alpha\r\n" is 7 UTF-16 units, "beta\r\n" another 6 — the CR is a
        // real unit even though Swift folds "\r\n" into one Character.
        #expect(lines.utf16Offset(ofLine: 1) == 7)
        #expect(lines.utf16Offset(ofLine: 2) == 13)
        #expect((text as NSString).substring(from: lines.utf16Offset(ofLine: 1)) == "beta\r\ngamma")
    }

    @Test func sourceLineMathClampsOutOfRange() {
        let lines = ReadingSourceLines("one\ntwo")
        #expect(lines.line(forUTF16Offset: -5) == 0)
        #expect(lines.line(forUTF16Offset: 9999) == 1)
        #expect(lines.utf16Offset(ofLine: -3) == 0)
        #expect(lines.utf16Offset(ofLine: 500) == 4)
    }

    @Test func topVisibleLinePicksTheBlockStraddlingTheTopEdge() {
        let offsets = [
            ReadingBlockOffset(line: 0, minY: -120),
            ReadingBlockOffset(line: 4, minY: -18),
            ReadingBlockOffset(line: 7, minY: 64),
            ReadingBlockOffset(line: 9, minY: 180),
        ]
        #expect(ReadingLayout.topVisibleLine(from: offsets) == 4)
        // Scrolled to the very top: nothing has passed the edge yet.
        #expect(ReadingLayout.topVisibleLine(from: [
            ReadingBlockOffset(line: 0, minY: 20),
            ReadingBlockOffset(line: 4, minY: 90),
        ]) == 0)
        #expect(ReadingLayout.topVisibleLine(from: []) == nil)
    }
}

// MARK: - Rendering model

struct ReadingRenderingTests {
    @Test func attributedRunsCarryLinksAndHighlights() {
        let model = blocks("go [[Target]] and ==lit== and [web](https://example.com)\n")
        guard case let .paragraph(inlines) = model[0].kind else {
            Issue.record("expected a paragraph")
            return
        }
        let attributed = ReadingInlineText.attributed(inlines, style: .default)
        #expect(String(attributed.characters).contains("Target"))
        let links = attributed.runs.compactMap(\.link)
        #expect(links.contains { $0.scheme == "notetaker-wikilink" })
        #expect(links.contains { $0.absoluteString == "https://example.com" })
        #expect(attributed.runs.contains { $0.backgroundColor != nil }, "the highlight tints")
    }

    @Test func imageSourcesResolveAgainstTheNoteFolder() {
        let base = URL(fileURLWithPath: "/vault/Projects")
        #expect(
            ReadingImageResolver.localURL("shots/a.png", base: base)?.path
                == "/vault/Projects/shots/a.png"
        )
        #expect(ReadingImageResolver.localURL("/abs/b.png", base: base)?.path == "/abs/b.png")
        #expect(ReadingImageResolver.localURL("https://x/y.png", base: base) == nil)
        #expect(ReadingImageResolver.remoteURL("https://x/y.png")?.host == "x")
        #expect(ReadingImageResolver.remoteURL("shots/a.png") == nil)
        #expect(ReadingImageResolver.localURL("shots/a.png", base: nil) == nil)
    }

    @Test func headingSizesMatchTheEditorLadder() {
        let style = ReadingStyle(baseFontSize: 16)
        #expect(style.headingSize(level: 1) == 26) // 16 * 1.6 rounded
        #expect(style.headingSize(level: 6) == 16)
        #expect(style.headingSize(level: 99) == 16, "out-of-range levels clamp")
        #expect(style.headingSize(level: 0) == 26)
    }

    @Test func escapedMarkdownRendersWithoutItsBackslash() {
        let model = blocks("a \\*literal\\* star and \\#nothashtag\n")
        guard case let .paragraph(inlines) = model[0].kind else {
            Issue.record("expected a paragraph")
            return
        }
        let text = ReadingInlineText.plainText(inlines)
        #expect(text == "a *literal* star and #nothashtag")
        #expect(!tokenNames(inlines).contains { $0.hasPrefix("tag:") })
    }

    @Test func emptyAndWhitespaceOnlySourcesProduceNoBlocks() {
        #expect(blocks("").isEmpty)
        #expect(blocks("\n\n\n").isEmpty)
        #expect(ReadingDocument.anchorLine(for: 3, in: blocks("")) == nil)
    }
}

import Foundation
import Markdown
import MarkdownKit
import TaskEngine

/// Markdown source → `[ReadingBlock]`. Pure: no I/O, no UI, no state — so
/// every structural decision Reading mode makes is unit-testable.
///
/// Two parsers feed it, both of them the app's existing ones:
/// `Markdown.Document` for structure (the same parse the editor styles) and
/// `MarkdownStyler.styleRanges` for the extended tokens that aren't
/// CommonMark. Task lines additionally go through `NoteScanner` +
/// `TaskTokenParser` — the exact pipeline the index runs — so a chip in
/// Reading mode and a row in the To-Do tab can never disagree.
public enum ReadingDocument {
    public static func build(from source: String) -> [ReadingBlock] {
        let document = MarkdownDocument(source: source)
        let lineOffset = frontmatterLineCount(document.frontmatter)
        let fileLines = splitLines(source)

        // Locked notes: the body is base64 ciphertext. One placeholder, and
        // nothing from the body reaches the renderer.
        if document.frontmatter?.values["locked"] == "true" {
            return [ReadingBlock(
                kind: .locked, firstLine: 0, lastLine: max(fileLines.count - 1, 0)
            )]
        }

        var blocks: [ReadingBlock] = []
        if let frontmatter = document.frontmatter, !frontmatter.values.isEmpty {
            // Keys sorted: `Frontmatter.values` is a dictionary, so file
            // order is already lost — sorted at least renders stably.
            let pairs = frontmatter.values
                .sorted { $0.key < $1.key }
                .map { ReadingKeyValue(key: $0.key, value: $0.value) }
            blocks.append(ReadingBlock(
                kind: .frontmatter(pairs), firstLine: 0, lastLine: max(lineOffset - 1, 0)
            ))
        }

        let builder = ReadingBuilder(
            body: document.body, lineOffset: lineOffset, fileLines: fileLines
        )
        let parsed = Markdown.Document(parsing: document.body, options: [.parseBlockDirectives])
        blocks.append(contentsOf: builder.blocks(
            in: parsed, fallback: lineOffset ... lineOffset
        ))
        return blocks
    }

    /// The scroll anchor for `line`: the block that contains it, else the
    /// last block that starts before it, else the first block. Returns nil
    /// only for an empty document.
    public static func anchorLine(for line: Int, in blocks: [ReadingBlock]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        if let hit = blocks.first(where: { $0.contains(line: line) }) {
            return hit.id
        }
        if let preceding = blocks.last(where: { $0.firstLine <= line }) {
            return preceding.id
        }
        return blocks.first?.id
    }

    /// Every task item in the document, flattened out of the list nesting —
    /// what the app walks to find the index row for a toggled checkbox.
    public static func taskItems(in blocks: [ReadingBlock]) -> [ReadingListItem] {
        var found: [ReadingListItem] = []
        func walk(_ blocks: [ReadingBlock]) {
            for block in blocks {
                switch block.kind {
                case let .list(_, _, items):
                    for item in items {
                        if item.checked != nil {
                            found.append(item)
                        }
                        walk(item.children)
                    }
                case let .blockquote(inner):
                    walk(inner)
                default:
                    continue
                }
            }
        }
        walk(blocks)
        return found
    }
}

// MARK: - Builder

/// One document's worth of parse state. `extended` is in `body` UTF-16
/// coordinates; line numbers come out in FILE coordinates.
struct ReadingBuilder {
    /// An extended-syntax token located by `MarkdownStyler`.
    struct ExtendedSpan {
        let range: NSRange
        let kind: MarkdownElementKind
    }

    let body: String
    let lineOffset: Int
    let fileLines: [String]
    private let sourceLines: ReadingSourceLines
    private let bodyNS: NSString
    private let extended: [ExtendedSpan]

    init(body: String, lineOffset: Int, fileLines: [String]) {
        self.body = body
        self.lineOffset = lineOffset
        self.fileLines = fileLines
        sourceLines = ReadingSourceLines(body)
        bodyNS = body as NSString
        // MarkdownStyler owns the wikilink/highlight/tag/mention/kind
        // regexes AND the "skip anything inside code" rule. Reading mode
        // re-uses that detection wholesale rather than adding a second,
        // drift-prone copy of the patterns.
        extended = MarkdownStyler.styleRanges(in: body).compactMap { styled in
            switch styled.kind {
            case .wikilink, .highlightMark, .tag, .mention, .kindToken:
                ExtendedSpan(range: styled.range, kind: styled.kind)
            default:
                nil
            }
        }
    }

    // MARK: Blocks

    func blocks(in container: Markup, fallback: ClosedRange<Int>) -> [ReadingBlock] {
        blocks(of: Array(container.children), fallback: fallback)
    }

    func blocks(of children: [Markup], fallback: ClosedRange<Int>) -> [ReadingBlock] {
        var result: [ReadingBlock] = []
        for child in children {
            let lines = lineRange(of: child, fallback: fallback)
            guard let kind = blockKind(of: child, lines: lines) else { continue }
            result.append(ReadingBlock(
                kind: kind, firstLine: lines.lowerBound, lastLine: lines.upperBound
            ))
        }
        return result
    }

    private func blockKind(of markup: Markup, lines: ClosedRange<Int>) -> ReadingBlock.Kind? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inlines: inlines(in: heading))
        case let paragraph as Paragraph:
            // A paragraph that is nothing but an image renders as a picture,
            // matching the editor's standalone-image thumbnail.
            if let image = soleImage(in: paragraph) {
                return .image(source: image.source ?? "", alt: image.plainText)
            }
            return .paragraph(inlines(in: paragraph))
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: listItems(in: list, fallback: lines))
        case let list as OrderedList:
            return .list(
                ordered: true, start: Int(list.startIndex),
                items: listItems(in: list, fallback: lines)
            )
        case let quote as BlockQuote:
            return .blockquote(blocks(in: quote, fallback: lines))
        case let code as CodeBlock:
            return .codeBlock(language: code.language, text: trimTrailingNewline(code.code))
        case let html as HTMLBlock:
            return .html(html.rawHTML)
        case is ThematicBreak:
            return .thematicBreak
        case let table as Markdown.Table:
            return tableKind(table)
        case let directive as BlockDirective:
            return .html(directive.format())
        case let text as PlainTextConvertibleMarkup:
            return .paragraph([.text(text.plainText)])
        default:
            return nil
        }
    }

    private func tableKind(_ table: Markdown.Table) -> ReadingBlock.Kind {
        let header: [ReadingTableCell] = table.head.cells
            .map { ReadingTableCell(inlines: inlines(in: $0)) }
        let rows: [[ReadingTableCell]] = table.body.rows.map { row in
            row.cells.map { ReadingTableCell(inlines: inlines(in: $0)) }
        }
        let alignments = table.columnAlignments.map { alignment in
            switch alignment {
            case .center: ReadingColumnAlignment.center
            case .right: ReadingColumnAlignment.trailing
            default: ReadingColumnAlignment.leading
            }
        }
        return .table(header: header, rows: rows, alignments: alignments)
    }

    private func soleImage(in paragraph: Paragraph) -> Markdown.Image? {
        let meaningful = paragraph.children.filter { child in
            if let text = child as? Markdown.Text {
                return !text.string.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return !(child is SoftBreak) && !(child is LineBreak)
        }
        guard meaningful.count == 1 else { return nil }
        return meaningful.first as? Markdown.Image
    }

    // MARK: List items

    private func listItems(in list: ListItemContainer, fallback: ClosedRange<Int>) -> [ReadingListItem] {
        list.listItems.map { item in
            let lines = lineRange(of: item, fallback: fallback)
            let checked = item.checkbox.map { $0 == .checked }
            // Everything under the item's own first paragraph: nested
            // lists, extra paragraphs, quoted notes.
            let children = blocks(of: Array(item.children.dropFirst()), fallback: lines)

            guard checked != nil else {
                return ReadingListItem(
                    inlines: firstParagraphInlines(of: item),
                    checked: nil,
                    task: nil,
                    sourceLine: lines.lowerBound,
                    children: children
                )
            }

            // Task line: re-scan the FILE line with the indexer's own
            // scanner so `text` is byte-identical to what TaskRecord holds,
            // then parse the tokens once. Chips come from the metadata;
            // whatever survives in cleanText renders as ordinary inlines
            // (so #tags keep their in-text position, exactly as the editor
            // shows them — see ReadingTaskChips for why they aren't
            // duplicated into the trailing chip row).
            let raw = fileLines.indices.contains(lines.lowerBound)
                ? strippingCarriageReturn(fileLines[lines.lowerBound])
                : ""
            guard let scanned = NoteScanner.tasks(in: raw).first else {
                return ReadingListItem(
                    inlines: firstParagraphInlines(of: item),
                    checked: checked,
                    task: nil,
                    sourceLine: lines.lowerBound,
                    children: children
                )
            }
            let parsed = TaskTokenParser.parse(scanned.text)
            return ReadingListItem(
                inlines: Self.fragmentInlines(parsed.cleanText),
                checked: checked,
                task: parsed,
                sourceLine: lines.lowerBound,
                children: children
            )
        }
    }

    private func firstParagraphInlines(of item: ListItem) -> [ReadingInline] {
        guard let paragraph = item.children.first(where: { $0 is Paragraph }) as? Paragraph
        else { return [] }
        return inlines(in: paragraph)
    }

    /// Inlines for a standalone snippet (a task's cleanText) — its own
    /// parse, its own extended-token scan, so the token coordinates stay
    /// straight.
    static func fragmentInlines(_ text: String) -> [ReadingInline] {
        guard !text.isEmpty else { return [] }
        let builder = ReadingBuilder(body: text, lineOffset: 0, fileLines: splitLines(text))
        let document = Markdown.Document(parsing: text, options: [.parseBlockDirectives])
        guard let paragraph = document.child(at: 0) as? Paragraph else {
            return [.text(text)]
        }
        return builder.inlines(in: paragraph)
    }

    // MARK: Inlines

    func inlines(in container: Markup) -> [ReadingInline] {
        var result: [ReadingInline] = []
        // cmark splits literal text at bracket boundaries, so "[[Note]]"
        // can arrive as several Text nodes. Merge the adjacent ones back
        // into one source span before looking for extended tokens.
        var pending: NSRange?

        func flush() {
            if let range = pending {
                result.append(contentsOf: segments(in: range))
                pending = nil
            }
        }

        for child in container.children {
            if let text = child as? Markdown.Text {
                if let range = child.range.flatMap({ sourceLines.nsRange(of: $0) }),
                   NSMaxRange(range) <= bodyNS.length {
                    if let previous = pending, NSMaxRange(previous) == range.location {
                        pending = NSUnionRange(previous, range)
                    } else {
                        flush()
                        pending = range
                    }
                } else {
                    flush()
                    result.append(contentsOf: Self.fragmentInlines(text.string))
                }
                continue
            }
            flush()
            result.append(contentsOf: convert(child))
        }
        flush()
        return result
    }

    private func convert(_ markup: Markup) -> [ReadingInline] {
        switch markup {
        case let strong as Strong:
            [.strong(inlines(in: strong))]
        case let emphasis as Emphasis:
            [.emphasis(inlines(in: emphasis))]
        case let strike as Strikethrough:
            [.strikethrough(inlines(in: strike))]
        case let code as InlineCode:
            [.code(code.code)]
        case let link as Link:
            [.link(destination: link.destination ?? "", children: inlines(in: link))]
        case let image as Markdown.Image:
            [.image(source: image.source ?? "", alt: image.plainText)]
        case let html as InlineHTML:
            [.text(html.rawHTML)]
        case let symbol as SymbolLink:
            [.code(symbol.destination ?? "")]
        case is LineBreak:
            [.lineBreak]
        case is SoftBreak:
            [.softBreak]
        case let attributes as InlineAttributes:
            inlines(in: attributes)
        case let text as PlainTextConvertibleMarkup:
            [.text(text.plainText)]
        default:
            []
        }
    }

    /// Splits a literal-text span on the extended tokens inside it.
    private func segments(in range: NSRange) -> [ReadingInline] {
        guard range.length > 0, NSMaxRange(range) <= bodyNS.length else { return [] }
        var result: [ReadingInline] = []
        var cursor = range.location
        for span in extended
            where span.range.location >= cursor
            && NSMaxRange(span.range) <= NSMaxRange(range) {
            if span.range.location > cursor {
                result.append(.text(unescape(bodyNS.substring(
                    with: NSRange(location: cursor, length: span.range.location - cursor)
                ))))
            }
            result.append(inline(for: span))
            cursor = NSMaxRange(span.range)
        }
        if cursor < NSMaxRange(range) {
            result.append(.text(unescape(bodyNS.substring(
                with: NSRange(location: cursor, length: NSMaxRange(range) - cursor)
            ))))
        }
        return result
    }

    private func inline(for span: ExtendedSpan) -> ReadingInline {
        switch span.kind {
        case let .wikilink(target):
            return .wikilink(target: target)
        case .highlightMark:
            // "==text==" — recurse so a token inside a highlight keeps its
            // own styling.
            let inner = NSRange(
                location: span.range.location + 2, length: max(span.range.length - 4, 0)
            )
            return .highlight(segments(in: inner))
        case let .tag(name):
            return .tag(name)
        case let .mention(name):
            return .mention(name)
        case let .kindToken(kind):
            return .kindToken(kind)
        default:
            return .text(bodyNS.substring(with: span.range))
        }
    }

    /// Markdown backslash escapes, resolved for display. cmark reports the
    /// unescaped character but we render from the source span (that is what
    /// keeps token offsets honest), so the backslash has to come off here.
    private func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                if character.isASCII, character.isPunctuation || character.isSymbol {
                    result.append(character)
                } else {
                    result.append("\\")
                    result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping {
            result.append("\\")
        }
        return result
    }

    // MARK: Lines

    /// FILE line range for a markup node. A block's upper bound usually
    /// points at column 1 of the line AFTER it, which would make every
    /// block overlap its neighbour — so that case steps back one line.
    private func lineRange(of markup: Markup, fallback: ClosedRange<Int>) -> ClosedRange<Int> {
        guard let range = markup.range else { return fallback }
        let first = range.lowerBound.line - 1 + lineOffset
        var last = range.upperBound.line - 1 + lineOffset
        if range.upperBound.column == 1, last > first {
            last -= 1
        }
        let low = max(min(first, last), 0)
        return low ... max(last, low)
    }

    private func trimTrailingNewline(_ text: String) -> String {
        var result = text
        while result.hasSuffix("\n") || result.hasSuffix("\r") {
            result.removeLast()
        }
        return result
    }
}

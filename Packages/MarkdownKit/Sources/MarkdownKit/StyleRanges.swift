import Foundation
import Markdown

/// What a range of markdown source *is*, for editor styling. One parse of
/// the body yields every range; EditorKit maps kinds to fonts/colors and
/// (in live-preview mode) hides syntax markers off the cursor line.
public enum MarkdownElementKind: Equatable, Sendable {
    case heading(level: Int)
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    case codeBlock(language: String?)
    case link(destination: String?)
    case blockQuote
    case listItem
    case taskCheckbox(checked: Bool)
    case thematicBreak
    case table
    /// `[[Note Title]]` — not CommonMark; detected by regex after the parse.
    case wikilink(target: String)
    /// `==marked text==` — not CommonMark; detected by regex after the parse.
    case highlightMark
    /// `![alt](source)` inline image.
    case image(source: String?)
    /// `#tag` — styled as a colored chip in the editor.
    case tag(String)
}

/// A styled span of the markdown body in UTF-16 (NSRange) coordinates —
/// ready for TextKit. Add `MarkdownDocument.bodyUTF16Offset` to position
/// ranges in the full file.
public struct StyledRange: Equatable, Sendable {
    public let kind: MarkdownElementKind
    public let range: NSRange

    public init(kind: MarkdownElementKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public enum MarkdownStyler {
    /// Parses the body and returns every styleable range, sorted by location.
    public static func styleRanges(in body: String) -> [StyledRange] {
        let document = Document(parsing: body, options: [.parseBlockDirectives])
        var walker = StyleWalker(converter: SourceConverter(body))
        walker.visit(document)
        var ranges = walker.ranges
        appendExtendedSyntax(in: body, to: &ranges)
        return ranges.sorted {
            ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length)
        }
    }

    private static let wikilinkRegex = try? NSRegularExpression(
        pattern: #"\[\[([^\[\]\n]+?)\]\]"#
    )
    private static let highlightRegex = try? NSRegularExpression(
        pattern: #"==([^=\n]+?)=="#
    )
    private static let editorTagRegex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)#([\p{L}\p{N}_][\p{L}\p{N}_\-/]*)"#
    )

    /// Wikilinks and highlight marks aren't CommonMark, so swift-markdown
    /// never emits them — a post-parse regex scan finds them, skipping any
    /// match inside code (spans/blocks), where the syntax is literal text.
    private static func appendExtendedSyntax(in body: String, to ranges: inout [StyledRange]) {
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        let codeRanges = ranges.compactMap { item -> NSRange? in
            switch item.kind {
            case .inlineCode, .codeBlock: item.range
            default: nil
            }
        }
        func insideCode(_ range: NSRange) -> Bool {
            codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for match in wikilinkRegex?.matches(in: body, range: full) ?? []
            where !insideCode(match.range) {
            let target = ns.substring(with: match.range(at: 1))
            ranges.append(StyledRange(kind: .wikilink(target: target), range: match.range))
        }
        for match in highlightRegex?.matches(in: body, range: full) ?? []
            where !insideCode(match.range) {
            ranges.append(StyledRange(kind: .highlightMark, range: match.range))
        }
        for match in editorTagRegex?.matches(in: body, range: full) ?? []
            where !insideCode(match.range) {
            let name = ns.substring(with: match.range(at: 1))
            ranges.append(StyledRange(kind: .tag(name), range: match.range))
        }
    }
}

// MARK: - Source-location conversion

/// swift-markdown reports 1-based line numbers and 1-based UTF-8 column
/// offsets; TextKit wants UTF-16 NSRanges. This converter bridges the two.
struct SourceConverter {
    private let lineStartUTF16: [Int]
    private let lines: [String]

    init(_ source: String) {
        // Scan for LF at the UTF-16 level: "\r\n" is a single Swift grapheme,
        // so Character-based search would miss every CRLF line break.
        let ns = source as NSString
        var starts = [0]
        var collected: [String] = []
        var lineStart = 0
        for offset in 0 ..< ns.length where ns.character(at: offset) == 0x0A {
            collected.append(ns.substring(with: NSRange(location: lineStart, length: offset - lineStart + 1)))
            starts.append(offset + 1)
            lineStart = offset + 1
        }
        if lineStart < ns.length {
            collected.append(ns.substring(from: lineStart))
        }
        lineStartUTF16 = starts
        lines = collected
    }

    /// UTF-16 offset for a swift-markdown SourceLocation.
    func utf16Offset(of location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < max(lines.count, 1) else {
            // Location just past the last line (e.g. range end at EOF).
            return lineIndex == lines.count ? lineStartUTF16.last : nil
        }
        guard !lines.isEmpty else { return 0 }
        let line = lines[lineIndex]
        let utf8Column = location.column - 1
        guard let index = line.utf8.index(
            line.utf8.startIndex, offsetBy: utf8Column, limitedBy: line.utf8.endIndex
        ) else {
            return lineStartUTF16[lineIndex] + line.utf16.count
        }
        return lineStartUTF16[lineIndex] + line[..<index].utf16.count
    }

    func nsRange(of range: SourceRange) -> NSRange? {
        guard let start = utf16Offset(of: range.lowerBound),
              let end = utf16Offset(of: range.upperBound),
              end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Walker

private struct StyleWalker: MarkupWalker {
    let converter: SourceConverter
    var ranges: [StyledRange] = []

    private mutating func append(_ kind: MarkdownElementKind, _ markup: Markup) {
        if let sourceRange = markup.range, let nsRange = converter.nsRange(of: sourceRange) {
            ranges.append(StyledRange(kind: kind, range: nsRange))
        }
    }

    mutating func visitHeading(_ heading: Heading) {
        append(.heading(level: heading.level), heading)
        descendInto(heading)
    }

    mutating func visitStrong(_ strong: Strong) {
        append(.strong, strong)
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        append(.emphasis, emphasis)
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        append(.strikethrough, strikethrough)
        descendInto(strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        append(.inlineCode, inlineCode)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        append(.codeBlock(language: codeBlock.language), codeBlock)
    }

    mutating func visitLink(_ link: Link) {
        append(.link(destination: link.destination), link)
        descendInto(link)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        append(.blockQuote, blockQuote)
        descendInto(blockQuote)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        append(.listItem, listItem)
        if let checked = listItem.checkbox.map({ $0 == .checked }) {
            append(.taskCheckbox(checked: checked), listItem)
        }
        descendInto(listItem)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        append(.thematicBreak, thematicBreak)
    }

    mutating func visitImage(_ image: Image) {
        append(.image(source: image.source), image)
    }

    mutating func visitTable(_ table: Markdown.Table) {
        append(.table, table)
        descendInto(table)
    }
}

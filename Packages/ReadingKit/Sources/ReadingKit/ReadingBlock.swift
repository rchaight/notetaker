import Foundation
import TaskEngine

/// A run of inline content in Reading mode. Formatting comes from the
/// swift-markdown AST; the extended tokens (`[[wikilink]]`, `==highlight==`,
/// `#tag`, `@person`, `?kind`) come from `MarkdownStyler`'s own detection, so
/// what Reading mode shows can never disagree with what the editor styles.
public enum ReadingInline: Equatable, Sendable {
    case text(String)
    case strong([ReadingInline])
    case emphasis([ReadingInline])
    case strikethrough([ReadingInline])
    case code(String)
    case link(destination: String, children: [ReadingInline])
    case image(source: String, alt: String)
    /// `[[Note Title]]` — target only; Reading mode routes a tap to the app.
    case wikilink(target: String)
    case highlight([ReadingInline])
    /// `#tag`, without the '#'.
    case tag(String)
    /// `@person`, without the '@'.
    case mention(String)
    /// `?discuss` … `?followup`, without the '?'.
    case kindToken(String)
    /// A `\` hard break.
    case lineBreak
    /// A newline inside a paragraph — rendered as a space.
    case softBreak
}

/// One `key: value` row of the frontmatter card.
public struct ReadingKeyValue: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public enum ReadingColumnAlignment: Equatable, Sendable {
    case leading, center, trailing
}

public struct ReadingTableCell: Equatable, Sendable {
    public let inlines: [ReadingInline]

    public init(inlines: [ReadingInline]) {
        self.inlines = inlines
    }
}

/// A list row. `checked` is non-nil exactly for `- [ ]` / `- [x]` task
/// items, and those carry the `TaskTokenParser` result so `>friday !p1
/// @robert ?discuss` render as chips instead of raw tokens.
public struct ReadingListItem: Equatable, Sendable {
    public let inlines: [ReadingInline]
    public let checked: Bool?
    /// Parsed task metadata; nil for a plain (non-checkbox) list item.
    public let task: ParsedTaskMetadata?
    /// 0-based FILE line of the item's first line — the same coordinate
    /// `TaskRecord.line` uses, so a toggle maps straight onto an index row.
    public let sourceLine: Int
    /// Nested content (sub-lists, extra paragraphs) under this item.
    public let children: [ReadingBlock]

    public init(
        inlines: [ReadingInline],
        checked: Bool? = nil,
        task: ParsedTaskMetadata? = nil,
        sourceLine: Int,
        children: [ReadingBlock] = []
    ) {
        self.inlines = inlines
        self.checked = checked
        self.task = task
        self.sourceLine = sourceLine
        self.children = children
    }
}

/// One rendered block, tagged with the source lines it came from. Position
/// sync between the editor and Reading mode rides entirely on these line
/// numbers, so they are FILE lines (frontmatter counted), 0-based.
public struct ReadingBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case frontmatter([ReadingKeyValue])
        case heading(level: Int, inlines: [ReadingInline])
        case paragraph([ReadingInline])
        case list(ordered: Bool, start: Int, items: [ReadingListItem])
        case blockquote([ReadingBlock])
        case codeBlock(language: String?, text: String)
        case table(
            header: [ReadingTableCell],
            rows: [[ReadingTableCell]],
            alignments: [ReadingColumnAlignment]
        )
        case thematicBreak
        case image(source: String, alt: String)
        /// Raw HTML / block directives — shown as literal text, never parsed.
        case html(String)
        /// An encrypted note: one placeholder instead of base64 soup.
        case locked
    }

    public let kind: Kind
    public let firstLine: Int
    public let lastLine: Int

    /// Scroll anchor id — the block's first source line.
    public var id: Int {
        firstLine
    }

    public var lines: ClosedRange<Int> {
        firstLine ... max(firstLine, lastLine)
    }

    public init(kind: Kind, firstLine: Int, lastLine: Int) {
        self.kind = kind
        self.firstLine = firstLine
        self.lastLine = lastLine
    }

    /// Whether this block's source covers `line`.
    public func contains(line: Int) -> Bool {
        lines.contains(line)
    }
}

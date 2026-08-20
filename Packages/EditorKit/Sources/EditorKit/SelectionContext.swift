import Foundation
import MarkdownKit

/// What the format bar should show for the current caret/selection: which
/// wrap styles are active, the heading level, and structural context
/// (code block / table / list / quote) that suppresses or informs those
/// buttons. Pure — computed from style ranges the highlighter already
/// produced, never a fresh parse.
public struct SelectionContext: Equatable, Sendable {
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var code = false
    /// 0 = body text; 1–6 = heading level for the current line.
    public var headingLevel = 0
    public var inCodeBlock = false
    public var inTable = false
    public var inList = false
    public var inQuote = false
    /// The enclosing link's full `[text](url)` range and destination, when
    /// the caret sits inside one.
    public var link: (range: NSRange, destination: String)?

    public init() {}

    public static func == (lhs: SelectionContext, rhs: SelectionContext) -> Bool {
        lhs.bold == rhs.bold
            && lhs.italic == rhs.italic
            && lhs.strikethrough == rhs.strikethrough
            && lhs.code == rhs.code
            && lhs.headingLevel == rhs.headingLevel
            && lhs.inCodeBlock == rhs.inCodeBlock
            && lhs.inTable == rhs.inTable
            && lhs.inList == rhs.inList
            && lhs.inQuote == rhs.inQuote
            && lhs.link?.range == rhs.link?.range
            && lhs.link?.destination == rhs.link?.destination
    }

    /// A style counts as active when the caret sits inside a range of that
    /// kind, or (for a non-empty selection) the selection is fully covered
    /// by it. One pass over the already-computed ranges — no re-parse.
    public static func at(_ selection: NSRange, ranges: [StyledRange]) -> SelectionContext {
        var context = SelectionContext()
        for item in ranges where covers(item.range, selection) {
            switch item.kind {
            case .strong:
                context.bold = true
            case .emphasis:
                context.italic = true
            case .strikethrough:
                context.strikethrough = true
            case .inlineCode:
                context.code = true
            case let .heading(level):
                context.headingLevel = level
            case .codeBlock:
                context.inCodeBlock = true
            case .table:
                context.inTable = true
            case .listItem:
                context.inList = true
            case .blockQuote:
                context.inQuote = true
            case let .link(destination):
                context.link = (range: item.range, destination: destination ?? "")
            default:
                break
            }
        }
        return context
    }

    private static func covers(_ outer: NSRange, _ selection: NSRange) -> Bool {
        if selection.length == 0 {
            return selection.location >= outer.location && selection.location <= NSMaxRange(outer)
        }
        return outer.location <= selection.location && NSMaxRange(selection) <= NSMaxRange(outer)
    }
}

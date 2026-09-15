import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Markdown table structure in UTF-16 coordinates — pure parsing, no
/// drawing. The grid renders in BOTH caret states: the pipes themselves are
/// the column separators, so entering a table never swaps one rendering for
/// another (`TableStyling` styles the text, `TableRowLayoutFragment` draws
/// the rules over it).
public enum TableGrid {
    public struct Row: Equatable, Sendable {
        public let range: NSRange
        public let cells: [String]
        public let isSeparator: Bool
    }

    public struct Region: Equatable, Sendable {
        public let range: NSRange
        public let rows: [Row]
        public var columnCount: Int {
            rows.map(\.cells.count).max() ?? 0
        }
    }

    public static func regions(in text: String, styled: [StyledRange]) -> [Region] {
        let ns = text as NSString
        var found: [Region] = []
        for item in styled {
            guard case .table = item.kind, NSMaxRange(item.range) <= ns.length else { continue }
            var rows: [Row] = []
            var offset = item.range.location
            for line in splitLines(ns.substring(with: item.range)) {
                let length = line.utf16.count
                defer { offset += length + 1 }
                let trimmed = strippingCarriageReturn(line).trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("|") else { continue }
                let lineRange = NSRange(location: offset, length: min(length, NSMaxRange(item.range) - offset))
                rows.append(Row(
                    range: lineRange, cells: cells(of: trimmed), isSeparator: isSeparatorRow(trimmed)
                ))
            }
            if rows.count >= 2 {
                found.append(Region(range: item.range, rows: rows))
            }
        }
        return found
    }

    /// Cell texts of one row, outer pipes stripped.
    static func cells(of line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparatorRow(_ line: String) -> Bool {
        let parts = cells(of: line)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } && cell.contains("-")
        }
    }

    /// Column x-offsets and widths from the widest cell per column.
    public static func columnLayout(
        for region: Region, headerFont: PlatformFont, bodyFont: PlatformFont
    ) -> [(x: CGFloat, width: CGFloat)] {
        let count = region.columnCount
        guard count > 0 else { return [] }
        var widths = [CGFloat](repeating: 44, count: count)
        for (rowIndex, row) in region.rows.enumerated() where !row.isSeparator {
            let font = rowIndex == 0 ? headerFont : bodyFont
            for (column, cell) in row.cells.enumerated() where column < count {
                let size = NSAttributedString(string: cell, attributes: [.font: font]).size()
                widths[column] = max(widths[column], size.width.rounded(.up) + 20)
            }
        }
        var x: CGFloat = 2
        return widths.map { width in
            defer { x += width }
            return (x: x, width: width)
        }
    }
}

/// Live Preview: the ONE table rendering, applied whether or not the caret
/// is inside the table. Table lines go monospaced (so the pipe columns line
/// up once the source is aligned), and the pipes plus the separator row's
/// dashes recede to the theme's separator color at FULL size — never
/// cleared, never 0.01pt. Attribute-only: the characters under the grid are
/// untouched, so Tab/Return cell navigation still walks the real string.
public enum TableStyling {
    public static func apply(
        to storage: NSTextStorage,
        text: String,
        styled: [StyledRange],
        theme: MarkdownTheme,
        clip: NSRange? = nil
    ) {
        let ns = text as NSString
        let font = theme.tableFont
        let separator = theme.tableSeparatorColor
        // `clip` is the incremental update's window: an unclipped write here
        // would re-inflate a table inside a FOLDED section, because the fold
        // pass that re-hides it is itself window-clipped (critic-caught).
        let bounds = clip.map { NSIntersectionRange($0, NSRange(location: 0, length: ns.length)) }
            ?? NSRange(location: 0, length: ns.length)
        func write(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            let target = NSIntersectionRange(range, bounds)
            guard target.length > 0 else { return }
            storage.addAttributes(attributes, range: target)
        }
        for item in styled {
            guard case .table = item.kind, NSMaxRange(item.range) <= ns.length,
                  NSIntersectionRange(item.range, bounds).length > 0 else { continue }
            // Re-asserting the font at full size also undoes any marker
            // collapse inside a cell: a 0.01pt run would knock the columns
            // out of the alignment the source was written with.
            write([.font: font], item.range)
            var offset = item.range.location
            for line in splitLines(ns.substring(with: item.range)) {
                let length = line.utf16.count
                defer { offset += length + 1 }
                let lineRange = NSRange(
                    location: offset,
                    length: min(length, max(NSMaxRange(item.range) - offset, 0))
                )
                guard lineRange.length > 0, NSMaxRange(lineRange) <= ns.length else { continue }
                let trimmed = strippingCarriageReturn(line).trimmingCharacters(in: .whitespaces)
                if TableGrid.isSeparatorRow(trimmed) {
                    // The whole row recedes — the fragment draws the header
                    // underline over it, but the dashes keep their height.
                    write([.foregroundColor: separator], lineRange)
                    continue
                }
                dimPipes(in: lineRange, of: ns, color: separator, write: write)
            }
        }
    }

    private static func dimPipes(
        in range: NSRange, of ns: NSString, color: PlatformColor,
        write: ([NSAttributedString.Key: Any], NSRange) -> Void
    ) {
        var search = range
        while search.length > 0 {
            let hit = ns.range(of: "|", options: [], range: search)
            guard hit.location != NSNotFound else { return }
            write([.foregroundColor: color], hit)
            let next = NSMaxRange(hit)
            search = NSRange(location: next, length: max(NSMaxRange(range) - next, 0))
        }
    }
}

/// Draws the grid over a table row: the header's tint, the rule above the
/// header, the header underline (the `| --- |` row), the rules between body
/// rows, and the table's bottom edge. It draws in BOTH caret states — the
/// row's own pipes stay visible as the vertical separators, so nothing is
/// redrawn or re-positioned when the caret enters.
public final class TableRowLayoutFragment: NSTextLayoutFragment {
    public var isHeader = false
    public var isSeparator = false
    public var isFirstRow = false
    public var isLastRow = false
    public var theme = MarkdownTheme.default

    /// Rules span the row's rendered text, not the text container: an
    /// aligned monospaced table is exactly as wide as its source lines.
    private var rowWidth: CGFloat {
        textLineFragments.reduce(0) { max($0, $1.typographicBounds.maxX) }
    }

    override public var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: 0, y: 0, width: rowWidth + 2, height: layoutFragmentFrame.height)
        )
    }

    override public func draw(at point: CGPoint, in context: CGContext) {
        let height = layoutFragmentFrame.height
        let width = rowWidth
        guard width > 8, height > 0 else {
            super.draw(at: point, in: context)
            return
        }
        context.saveGState()
        if isHeader {
            context.setFillColor(theme.surfaceBackground.cgColor)
            context.fill(CGRect(x: point.x, y: point.y, width: width, height: height))
        }
        context.setStrokeColor(theme.tableSeparatorColor.cgColor)
        context.setLineWidth(isSeparator ? 1 : 0.5)
        if isFirstRow {
            context.stroke(CGRect(x: point.x, y: point.y, width: width, height: 0))
        }
        if isSeparator {
            // The separator row IS the header underline.
            context.stroke(CGRect(
                x: point.x, y: point.y + (height / 2).rounded(), width: width, height: 0
            ))
        } else if !isHeader {
            // A rule under every body row; the header's own is the
            // separator row's underline, so drawing it would double up.
            context.stroke(CGRect(x: point.x, y: point.y + height, width: width, height: 0))
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

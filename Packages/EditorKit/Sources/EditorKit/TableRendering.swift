import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Markdown table structure in UTF-16 coordinates — pure parsing, no
/// drawing. The grid renders when the cursor is OUTSIDE the table; inside,
/// the raw pipe syntax comes back for editing.
public enum TableGrid {
    public struct Row: Equatable, Sendable {
        public let range: NSRange
        public let cells: [String]
        public let isSeparator: Bool
    }

    public struct Region: Equatable, Sendable {
        public let range: NSRange
        public let rows: [Row]
        public var columnCount: Int { rows.map(\.cells.count).max() ?? 0 }
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
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
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

/// Draws one table row as a grid slice: header tint, cell borders, and the
/// cell texts at computed column positions (the raw pipe text renders clear
/// underneath, so offsets and selection stay on the real string).
public final class TableRowLayoutFragment: NSTextLayoutFragment {
    public var cells: [String] = []
    public var columns: [(x: CGFloat, width: CGFloat)] = []
    public var isHeader = false
    public var isSeparator = false
    public var isFirstRow = false
    public var isLastRow = false
    public var theme = MarkdownTheme.default

    private var tableWidth: CGFloat {
        (columns.last.map { $0.x + $0.width } ?? 0) + 2
    }

    override public var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: 0, y: 0, width: tableWidth, height: layoutFragmentFrame.height)
        )
    }

    override public func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        let height = layoutFragmentFrame.height
        let width = tableWidth
        guard width > 8, height > 0 else { return }
        context.saveGState()
        let border = theme.focusDimColor.cgColor
        if isHeader {
            context.setFillColor(theme.surfaceBackground.cgColor)
            context.fill(CGRect(x: point.x + 2, y: point.y, width: width - 4, height: height))
        }
        context.setStrokeColor(border)
        context.setLineWidth(isSeparator ? 1.5 : 0.5)
        // Horizontal borders: top edge on the first row, bottom edge always.
        if isFirstRow {
            context.stroke(CGRect(x: point.x + 2, y: point.y, width: width - 4, height: 0))
        }
        context.stroke(CGRect(
            x: point.x + 2, y: point.y + height, width: width - 4, height: 0
        ))
        // Vertical column separators.
        if !isSeparator {
            context.setLineWidth(0.5)
            for column in columns {
                context.stroke(CGRect(x: point.x + column.x, y: point.y, width: 0, height: height))
            }
            context.stroke(CGRect(x: point.x + width - 2, y: point.y, width: 0, height: height))
        }
        context.restoreGState()
        guard !isSeparator else { return }
        let font = isHeader ? theme.tableHeaderFont : theme.baseFont
        for (index, cell) in cells.enumerated() where index < columns.count {
            let string = NSAttributedString(string: cell, attributes: [
                .font: font, .foregroundColor: theme.textColor,
            ])
            let size = string.size()
            let origin = CGPoint(
                x: point.x + columns[index].x + 10,
                y: point.y + max((height - size.height) / 2, 0)
            )
            #if canImport(AppKit)
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                string.draw(at: origin)
                NSGraphicsContext.current = previous
            #else
                UIGraphicsPushContext(context)
                string.draw(at: origin)
                UIGraphicsPopContext()
            #endif
        }
    }
}

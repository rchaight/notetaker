import Foundation
import MarkdownKit

/// Structural editing for markdown pipe tables: which cell the cursor sits
/// in, where Tab goes next, row/column insert + delete, and pipe
/// alignment. Pure UTF-16 string work layered over `TableGrid`'s parse —
/// the editor coordinators only translate keys into these calls, so the
/// same logic serves the format bar, App Intents, and iOS.
public enum TableEditing {
    // MARK: - Shapes

    /// Where a location lands in a table: the region, its row/column, and
    /// the cell's text range with pipes and padding excluded.
    public struct Cell: Equatable, Sendable {
        public let region: TableGrid.Region
        public let rowIndex: Int
        public let columnIndex: Int
        public let contentRange: NSRange
    }

    /// A Tab target is usually a pure selection move; Tab in the last cell
    /// has to grow the table first.
    public enum CellMove: Equatable, Sendable {
        case select(NSRange)
        case edit(EditResult)
    }

    /// Column alignment as encoded by the separator row's `:` markers.
    enum ColumnAlignment: Equatable {
        case none, left, right, center
    }

    // MARK: - Regions

    public static func regions(in text: String) -> [TableGrid.Region] {
        TableGrid.regions(in: text, styled: MarkdownStyler.styleRanges(in: text))
    }

    /// End-inclusive: a cursor parked at the end of the last row is still
    /// in the table.
    public static func region(
        containing location: Int, in regions: [TableGrid.Region]
    ) -> TableGrid.Region? {
        regions.first { location >= $0.range.location && location <= NSMaxRange($0.range) }
    }

    /// Parsing a long note costs real time and Tab/Return fire constantly —
    /// a pipe on the cursor's line is the cheap precondition for any table
    /// work, so ordinary typing never pays for a parse.
    static func lineCouldBeTableRow(in text: String, location: Int) -> Bool {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return false }
        let line = ns.paragraphRange(for: NSRange(location: location, length: 0))
        return ns.range(of: "|", options: [], range: line).location != NSNotFound
    }

    // MARK: - Cell resolution

    public static func cell(
        at location: Int, in text: String, regions: [TableGrid.Region]
    ) -> Cell? {
        guard let region = region(containing: location, in: regions) else { return nil }
        let ns = text as NSString
        guard let rowIndex = region.rows.firstIndex(where: {
            location >= $0.range.location && location <= NSMaxRange($0.range)
        }) else { return nil }
        let row = layout(of: region.rows[rowIndex], in: ns)
        guard !row.cellRanges.isEmpty else { return nil }
        // On a pipe, the cell to the LEFT owns the cursor — that is the one
        // the user just finished typing in.
        let column = row.cellRanges.lastIndex { $0.location <= location } ?? 0
        return Cell(
            region: region, rowIndex: rowIndex, columnIndex: column,
            contentRange: row.cellRanges[column]
        )
    }

    public static func cell(at location: Int, in text: String) -> Cell? {
        guard lineCouldBeTableRow(in: text, location: location) else { return nil }
        return cell(at: location, in: text, regions: regions(in: text))
    }

    // MARK: - Tab navigation

    /// Left-to-right, top-to-bottom, separator row skipped. Tab in the last
    /// cell appends an empty row and lands in its first cell.
    public static func nextCell(in text: String, selection: NSRange) -> CellMove? {
        guard let cell = cell(at: selection.location, in: text) else { return nil }
        let ns = text as NSString
        let rows = cell.region.rows
        let current = layout(of: rows[cell.rowIndex], in: ns)
        if !current.isSeparator, cell.columnIndex + 1 < current.cellRanges.count {
            return .select(current.cellRanges[cell.columnIndex + 1])
        }
        if let next = (cell.rowIndex + 1 ..< rows.count).first(where: { !rows[$0].isSeparator }) {
            return .select(firstCellRange(of: rows[next], in: ns))
        }
        guard let edit = insertRow(in: text, region: cell.region, afterRow: rows.count - 1)
        else { return nil }
        return .edit(edit)
    }

    /// Mirror of `nextCell`; Shift-Tab in the very first cell stays put
    /// (returning nil would let AppKit move focus out of the editor).
    public static func previousCell(in text: String, selection: NSRange) -> CellMove? {
        guard let cell = cell(at: selection.location, in: text) else { return nil }
        let ns = text as NSString
        let rows = cell.region.rows
        let current = layout(of: rows[cell.rowIndex], in: ns)
        if !current.isSeparator, cell.columnIndex > 0 {
            return .select(current.cellRanges[cell.columnIndex - 1])
        }
        if let previous = (0 ..< cell.rowIndex).last(where: { !rows[$0].isSeparator }) {
            let row = layout(of: rows[previous], in: ns)
            return .select(row.cellRanges.last ?? firstCellRange(of: rows[previous], in: ns))
        }
        return .select(cell.contentRange)
    }

    private static func firstCellRange(of row: TableGrid.Row, in ns: NSString) -> NSRange {
        let layout = layout(of: row, in: ns)
        return layout.cellRanges.first ?? NSRange(location: layout.range.location, length: 0)
    }

    // MARK: - Rows

    /// Adds an empty row under `rowIndex`. Targets above the separator are
    /// pushed below it so the header block stays structurally valid.
    public static func insertRow(
        in text: String, region: TableGrid.Region, afterRow rowIndex: Int
    ) -> EditResult? {
        guard region.rows.indices.contains(rowIndex) else { return nil }
        let ns = text as NSString
        var target = rowIndex
        if let separator = region.rows.firstIndex(where: \.isSeparator), target < separator {
            target = separator
        }
        let anchor = region.rows[target]
        let template = layout(of: anchor, in: ns)
        let line = template.indent + "|" + String(repeating: "  |", count: max(region.columnCount, 1))
        let location = NSMaxRange(anchor.range)
        // "\n" + indent + "|" + one padding space = the first cell's caret.
        let caret = location + 1 + (template.indent as NSString).length + 2
        return EditResult(
            range: NSRange(location: location, length: 0),
            replacement: "\n" + line,
            selection: NSRange(location: caret, length: 0)
        )
    }

    /// The separator is structure, not content, so it never deletes on its
    /// own; removing the last data row (or the header of a table with no
    /// data rows) takes the whole block.
    public static func deleteRow(
        in text: String, region: TableGrid.Region, at rowIndex: Int
    ) -> EditResult? {
        let rows = region.rows
        guard rows.indices.contains(rowIndex) else { return nil }
        let separator = rows.firstIndex(where: \.isSeparator)
        guard rowIndex != separator else { return nil }
        let dataRows = rows.indices.filter { $0 != 0 && $0 != separator }
        if rowIndex == 0 {
            // Deleting the header promotes the first data row into it —
            // anything else would leave the separator on top.
            guard let separator, let first = dataRows.first else {
                return deleteTable(in: text, region: region)
            }
            let ns = text as NSString
            let promoted = ns.substring(with: rows[first].range)
            let rule = ns.substring(with: rows[separator].range)
            let range = NSRange(
                location: rows[0].range.location,
                length: NSMaxRange(rows[first].range) - rows[0].range.location
            )
            return EditResult(
                range: range, replacement: promoted + "\n" + rule,
                selection: NSRange(location: rows[0].range.location, length: 0)
            )
        }
        guard dataRows.count > 1 else { return deleteTable(in: text, region: region) }
        let range = lineRange(rows[rowIndex].range, in: text)
        return EditResult(
            range: range, replacement: "",
            selection: NSRange(location: range.location, length: 0)
        )
    }

    // MARK: - Columns

    public static func insertColumn(
        in text: String, region: TableGrid.Region, afterColumn columnIndex: Int, anchorRow: Int? = nil
    ) -> EditResult? {
        rewriteRows(
            in: text, region: region, anchorRow: anchorRow, anchorColumn: columnIndex + 1
        ) { row in
            var segments = row.segments
            let index = min(max(columnIndex + 1, 0), segments.count)
            segments.insert(row.isSeparator ? " --- " : "  ", at: index)
            return segments
        }
    }

    /// A table with one column left is just pipes around text — removing it
    /// removes the block.
    public static func deleteColumn(
        in text: String, region: TableGrid.Region, at columnIndex: Int, anchorRow: Int? = nil
    ) -> EditResult? {
        guard region.columnCount > 1 else { return deleteTable(in: text, region: region) }
        return rewriteRows(
            in: text, region: region, anchorRow: anchorRow, anchorColumn: columnIndex
        ) { row in
            var segments = row.segments
            guard segments.indices.contains(columnIndex) else { return segments }
            segments.remove(at: columnIndex)
            return segments
        }
    }

    // MARK: - Alignment

    /// Every column padded to its widest cell (min width 3) with the
    /// separator row rebuilt at the same widths, `:` markers preserved.
    /// Idempotent: widths come from trimmed cell text, so re-running on the
    /// output reproduces it exactly.
    public static func aligned(region: TableGrid.Region, in text: String) -> String {
        let ns = text as NSString
        let rows = region.rows.map { layout(of: $0, in: ns) }
        let columns = max(rows.map(\.segments.count).max() ?? 0, 1)
        guard !rows.isEmpty else { return ns.substring(with: region.range) }
        let indent = rows[0].indent
        var widths = [Int](repeating: 3, count: columns)
        for row in rows where !row.isSeparator {
            for (index, segment) in row.segments.enumerated() where index < columns {
                widths[index] = max(widths[index], trimmed(segment).count)
            }
        }
        let alignments = rows.first(where: \.isSeparator).map { rule in
            (0 ..< columns).map { index -> ColumnAlignment in
                index < rule.segments.count ? alignment(of: trimmed(rule.segments[index])) : .none
            }
        } ?? [ColumnAlignment](repeating: .none, count: columns)

        return rows.map { row -> String in
            let cells = (0 ..< columns).map { index -> String in
                if row.isSeparator {
                    return " " + rule(alignments[index], width: widths[index]) + " "
                }
                let value = index < row.segments.count ? trimmed(row.segments[index]) : ""
                return " " + value + String(repeating: " ", count: max(widths[index] - value.count, 0)) + " "
            }
            return indent + "|" + cells.joined(separator: "|") + "|"
        }.joined(separator: "\n")
    }

    /// `aligned` as an edit, with the selection carried across: inside the
    /// table it follows its cell, outside it just shifts by the delta.
    /// Returns nil when the table is already aligned — no undo noise.
    public static func align(
        in text: String, region: TableGrid.Region, selection: NSRange
    ) -> EditResult? {
        let ns = text as NSString
        let replacement = aligned(region: region, in: text)
        guard replacement != ns.substring(with: region.range) else { return nil }
        let delta = (replacement as NSString).length - region.range.length
        var target = NSRange(location: region.range.location, length: 0)
        if selection.location <= region.range.location {
            target = selection
        } else if selection.location >= NSMaxRange(region.range) {
            target = NSRange(location: selection.location + delta, length: 0)
        } else if let cell = cell(at: selection.location, in: text, regions: [region]),
                  let mapped = cellRange(
                      inRegionText: replacement, startingAt: region.range.location,
                      row: cell.rowIndex, column: cell.columnIndex
                  ) {
            target = mapped
        }
        let limit = ns.length + delta
        target = NSRange(
            location: min(max(target.location, 0), limit),
            length: min(target.length, max(limit - target.location, 0))
        )
        return EditResult(range: region.range, replacement: replacement, selection: target)
    }

    /// Auto-align on leave: the table is identified by the start location
    /// the cursor was inside, re-resolved against the current text (edits
    /// happened *inside* the table, so its start never moved).
    public static func alignEdit(
        in text: String, anchoredAt anchor: Int, selection: NSRange
    ) -> EditResult? {
        let found = regions(in: text)
        guard let region = found.first(where: { $0.range.location == anchor })
            ?? region(containing: anchor, in: found) else { return nil }
        return align(in: text, region: region, selection: selection)
    }

    // MARK: - Command path

    /// Format bar / iOS: resolve the cursor's table and run the operation.
    /// Every case is a safe no-op when the selection is not in a table.
    static func edit(for command: EditorCommand, in text: String, selection: NSRange) -> EditResult? {
        guard let cell = cell(at: selection.location, in: text) else { return nil }
        switch command {
        case .tableInsertRow:
            return insertRow(in: text, region: cell.region, afterRow: cell.rowIndex)
        case .tableInsertColumn:
            return insertColumn(
                in: text, region: cell.region, afterColumn: cell.columnIndex, anchorRow: cell.rowIndex
            )
        case .tableDeleteRow:
            return deleteRow(in: text, region: cell.region, at: cell.rowIndex)
        case .tableDeleteColumn:
            return deleteColumn(
                in: text, region: cell.region, at: cell.columnIndex, anchorRow: cell.rowIndex
            )
        case .tableAlign:
            return align(in: text, region: cell.region, selection: selection)
        default:
            return nil
        }
    }

    // MARK: - Row layout

    /// One row split at its pipes: the raw text between them (so a rebuild
    /// keeps untouched cells byte-for-byte) plus each cell's trimmed
    /// content range in document coordinates.
    struct RowLayout {
        let range: NSRange
        let indent: String
        let leadingPipe: Bool
        let trailingPipe: Bool
        let segments: [String]
        let cellRanges: [NSRange]
        let isSeparator: Bool
    }

    static func layout(of row: TableGrid.Row, in ns: NSString) -> RowLayout {
        layout(line: ns.substring(with: row.range), at: row.range.location, isSeparator: row.isSeparator)
    }

    static func layout(line: String, at location: Int, isSeparator: Bool? = nil) -> RowLayout {
        let ns = line as NSString
        var start = 0
        while start < ns.length, isBlank(ns.character(at: start)) {
            start += 1
        }
        var end = ns.length
        while end > start, isBlank(ns.character(at: end - 1)) {
            end -= 1
        }
        var contentStart = start
        var contentEnd = end
        let leadingPipe = contentStart < contentEnd && ns.character(at: contentStart) == pipe
        if leadingPipe {
            contentStart += 1
        }
        let trailingPipe = contentEnd > contentStart && ns.character(at: contentEnd - 1) == pipe
        if trailingPipe {
            contentEnd -= 1
        }

        var segments: [String] = []
        var ranges: [NSRange] = []
        var segmentStart = contentStart
        var index = contentStart
        while index <= contentEnd {
            if index == contentEnd || ns.character(at: index) == pipe {
                let bounds = NSRange(location: segmentStart, length: index - segmentStart)
                segments.append(ns.substring(with: bounds))
                let content = contentRange(of: bounds, in: ns)
                ranges.append(NSRange(location: content.location + location, length: content.length))
                segmentStart = index + 1
            }
            index += 1
        }
        return RowLayout(
            range: NSRange(location: location, length: ns.length),
            indent: ns.substring(to: start),
            leadingPipe: leadingPipe,
            trailingPipe: trailingPipe,
            segments: segments,
            cellRanges: ranges,
            isSeparator: isSeparator ?? TableGrid.isSeparatorRow(
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    /// Trimmed cell text; an empty cell parks the caret inside its padding
    /// rather than on a pipe.
    private static func contentRange(of range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isBlank(ns.character(at: start)) {
            start += 1
        }
        while end > start, isBlank(ns.character(at: end - 1)) {
            end -= 1
        }
        guard start < end else {
            return NSRange(location: min(range.location + 1, NSMaxRange(range)), length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Rewriting helpers

    /// Rebuilds every row of the region through `transform` and returns one
    /// edit for the whole block; the selection lands on `anchorColumn` of
    /// the row that held it (or `anchorRow` when given).
    private static func rewriteRows(
        in text: String,
        region: TableGrid.Region,
        anchorRow: Int?,
        anchorColumn: Int,
        transform: (RowLayout) -> [String]
    ) -> EditResult? {
        let ns = text as NSString
        var lines: [String] = []
        var cursor = region.range.location
        var carried = ""
        for row in region.rows {
            guard row.range.location >= cursor else { continue }
            carried += ns.substring(
                with: NSRange(location: cursor, length: row.range.location - cursor)
            )
            let layout = layout(of: row, in: ns)
            let rebuilt = layout.indent
                + (layout.leadingPipe ? "|" : "")
                + transform(layout).joined(separator: "|")
                + (layout.trailingPipe ? "|" : "")
            carried += rebuilt
            lines.append(rebuilt)
            cursor = NSMaxRange(row.range)
        }
        guard !lines.isEmpty else { return nil }
        carried += ns.substring(
            with: NSRange(location: cursor, length: NSMaxRange(region.range) - cursor)
        )
        // Without a caller-supplied row the caret goes to the first row
        // that carries content.
        let row = anchorRow ?? region.rows.firstIndex(where: { !$0.isSeparator }) ?? 0
        let selection = cellRange(
            inRegionText: carried, startingAt: region.range.location,
            row: row, column: anchorColumn
        ) ?? NSRange(location: region.range.location, length: 0)
        return EditResult(range: region.range, replacement: carried, selection: selection)
    }

    private static func cellRange(
        inRegionText regionText: String, startingAt origin: Int, row: Int, column: Int
    ) -> NSRange? {
        let lines = regionText.components(separatedBy: "\n")
        guard lines.indices.contains(row) else { return nil }
        var location = origin
        for index in 0 ..< row {
            location += (lines[index] as NSString).length + 1
        }
        let layout = layout(line: lines[row], at: location)
        guard !layout.cellRanges.isEmpty else { return nil }
        return layout.cellRanges[min(max(column, 0), layout.cellRanges.count - 1)]
    }

    private static func deleteTable(in text: String, region: TableGrid.Region) -> EditResult {
        let range = lineRange(region.range, in: text)
        return EditResult(
            range: range, replacement: "",
            selection: NSRange(location: range.location, length: 0)
        )
    }

    /// Extends a block range over the newline that ends it — or, at end of
    /// file, the one in front of it — so deleting leaves no blank line.
    private static func lineRange(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        var extended = range
        if NSMaxRange(extended) < ns.length, ns.character(at: NSMaxRange(extended)) == newline {
            extended.length += 1
        } else if extended.location > 0, ns.character(at: extended.location - 1) == newline {
            extended.location -= 1
            extended.length += 1
        }
        return extended
    }

    // MARK: - Small helpers

    private static let pipe: unichar = 0x7C
    private static let newline: unichar = 0x0A

    /// Includes CR so a CRLF note's rows do not carry a stray return into
    /// their last cell.
    private static func isBlank(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0D
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func alignment(of separatorCell: String) -> ColumnAlignment {
        let left = separatorCell.hasPrefix(":")
        let right = separatorCell.hasSuffix(":")
        return switch (left, right) {
        case (true, true): .center
        case (true, false): .left
        case (false, true): .right
        default: .none
        }
    }

    private static func rule(_ alignment: ColumnAlignment, width: Int) -> String {
        let span = max(width, 3)
        return switch alignment {
        case .none: String(repeating: "-", count: span)
        case .left: ":" + String(repeating: "-", count: span - 1)
        case .right: String(repeating: "-", count: span - 1) + ":"
        case .center: ":" + String(repeating: "-", count: span - 2) + ":"
        }
    }
}

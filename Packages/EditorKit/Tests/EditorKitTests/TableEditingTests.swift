@testable import EditorKit
import Foundation
import MarkdownKit
import Testing

struct TableEditingTests {
    /// A 2-column table with one data row; every offset in these tests is
    /// derived from `location(of:)` so the fixtures stay readable.
    private let table = """
    | Name | Role |
    | --- | --- |
    | Ada | Engineer |
    """

    private func firstRegion(_ text: String) throws -> TableGrid.Region {
        try #require(TableEditing.regions(in: text).first)
    }

    private func location(of needle: String, in text: String) throws -> Int {
        let range = (text as NSString).range(of: needle)
        try #require(range.location != NSNotFound)
        return range.location
    }

    private func applied(_ result: EditResult, to text: String) -> String {
        (text as NSString).replacingCharacters(in: result.range, with: result.replacement)
    }

    private func selected(_ result: EditResult, in text: String) -> String {
        let updated = applied(result, to: text) as NSString
        guard NSMaxRange(result.selection) <= updated.length else { return "<out of bounds>" }
        return updated.substring(with: result.selection)
    }

    // MARK: - Cell resolution

    @Test func resolvesTheFirstCell() throws {
        let cell = try #require(try TableEditing.cell(at: location(of: "Name", in: table), in: table))
        #expect(cell.rowIndex == 0)
        #expect(cell.columnIndex == 0)
        #expect((table as NSString).substring(with: cell.contentRange) == "Name")
    }

    @Test func resolvesTheLastCell() throws {
        let cell = try #require(try TableEditing.cell(at: location(of: "Engineer", in: table), in: table))
        #expect(cell.rowIndex == 2)
        #expect(cell.columnIndex == 1)
        #expect((table as NSString).substring(with: cell.contentRange) == "Engineer")
    }

    @Test func resolvesTheSeparatorRow() throws {
        let cell = try #require(try TableEditing.cell(at: location(of: "--- |", in: table), in: table))
        #expect(cell.rowIndex == 1)
        #expect(cell.region.rows[cell.rowIndex].isSeparator)
    }

    @Test func cursorOnAPipeBelongsToTheCellOnItsLeft() throws {
        // The pipe between "Name" and "Role".
        let pipe = try location(of: "Name", in: table) + 5
        #expect((table as NSString).substring(with: NSRange(location: pipe, length: 1)) == "|")
        let cell = try #require(TableEditing.cell(at: pipe, in: table))
        #expect(cell.columnIndex == 0)
    }

    @Test func cursorOutsideEveryTableResolvesToNothing() throws {
        let text = "Just a sentence.\n\n\(table)\n"
        #expect(TableEditing.cell(at: 3, in: text) == nil)
        #expect(try TableEditing.cell(at: location(of: "Ada", in: text), in: text) != nil)
    }

    // MARK: - Tab navigation

    @Test func tabWalksLeftToRight() throws {
        let move = try TableEditing.nextCell(
            in: table, selection: NSRange(location: location(of: "Name", in: table), length: 4)
        )
        guard case let .select(range) = try #require(move) else {
            Issue.record("expected a selection move")
            return
        }
        #expect((table as NSString).substring(with: range) == "Role")
    }

    @Test func tabAtTheEndOfARowSkipsTheSeparator() throws {
        let move = try TableEditing.nextCell(
            in: table, selection: NSRange(location: location(of: "Role", in: table), length: 4)
        )
        guard case let .select(range) = try #require(move) else {
            Issue.record("expected a selection move")
            return
        }
        #expect((table as NSString).substring(with: range) == "Ada")
    }

    @Test func tabInTheLastCellAppendsARow() throws {
        let move = try TableEditing.nextCell(
            in: table, selection: NSRange(location: location(of: "Engineer", in: table), length: 8)
        )
        guard case let .edit(edit) = try #require(move) else {
            Issue.record("expected a text edit")
            return
        }
        let updated = applied(edit, to: table)
        #expect(updated == table + "\n|  |  |")
        // The caret lands in the new row's first cell.
        #expect(edit.selection.length == 0)
        #expect(edit.selection.location == (updated as NSString).length - 5)
    }

    @Test func shiftTabWalksBackwardAndStopsInTheFirstCell() throws {
        let back = try TableEditing.previousCell(
            in: table, selection: NSRange(location: location(of: "Ada", in: table), length: 3)
        )
        guard case let .select(range) = try #require(back) else {
            Issue.record("expected a selection move")
            return
        }
        // Up past the separator, to the header's last cell.
        #expect((table as NSString).substring(with: range) == "Role")

        let stay = try TableEditing.previousCell(
            in: table, selection: NSRange(location: location(of: "Name", in: table), length: 4)
        )
        guard case let .select(held) = try #require(stay) else {
            Issue.record("expected a selection move")
            return
        }
        #expect((table as NSString).substring(with: held) == "Name")
    }

    @Test func navigationOutsideATableDoesNothing() {
        let text = "- [ ] a task\n"
        #expect(TableEditing.nextCell(in: text, selection: NSRange(location: 6, length: 0)) == nil)
        #expect(TableEditing.previousCell(in: text, selection: NSRange(location: 6, length: 0)) == nil)
    }

    // MARK: - Rows

    @Test func insertRowAddsAnEmptyRowBelow() throws {
        let region = try firstRegion(table)
        let edit = try #require(TableEditing.insertRow(in: table, region: region, afterRow: 2))
        #expect(applied(edit, to: table) == table + "\n|  |  |")
    }

    @Test func insertRowFromTheHeaderLandsBelowTheSeparator() throws {
        let region = try firstRegion(table)
        let edit = try #require(TableEditing.insertRow(in: table, region: region, afterRow: 0))
        #expect(applied(edit, to: table) == """
        | Name | Role |
        | --- | --- |
        |  |  |
        | Ada | Engineer |
        """)
    }

    @Test func deleteRowRemovesOneDataRow() throws {
        let text = table + "\n| Grace | Admiral |\n"
        let region = try firstRegion(text)
        let edit = try #require(TableEditing.deleteRow(in: text, region: region, at: 3))
        #expect(applied(edit, to: text) == table + "\n")
    }

    @Test func deletingTheLastDataRowDeletesTheTable() throws {
        let text = "Before\n\n\(table)\n\nAfter\n"
        let region = try firstRegion(text)
        let edit = try #require(TableEditing.deleteRow(in: text, region: region, at: 2))
        #expect(applied(edit, to: text) == "Before\n\n\nAfter\n")
    }

    @Test func deletingTheHeaderPromotesTheFirstDataRow() throws {
        let text = table + "\n| Grace | Admiral |\n"
        let region = try firstRegion(text)
        let edit = try #require(TableEditing.deleteRow(in: text, region: region, at: 0))
        #expect(applied(edit, to: text) == """
        | Ada | Engineer |
        | --- | --- |
        | Grace | Admiral |

        """)
    }

    @Test func deletingTheSeparatorRowIsRefused() throws {
        let region = try firstRegion(table)
        #expect(TableEditing.deleteRow(in: table, region: region, at: 1) == nil)
    }

    // MARK: - Columns

    @Test func insertColumnAddsACellToEveryRow() throws {
        let region = try firstRegion(table)
        let edit = try #require(TableEditing.insertColumn(in: table, region: region, afterColumn: 0))
        #expect(applied(edit, to: table) == """
        | Name |  | Role |
        | --- | --- | --- |
        | Ada |  | Engineer |
        """)
        #expect(selected(edit, in: table) == "")
    }

    @Test func deleteColumnRemovesThatCellFromEveryRow() throws {
        let region = try firstRegion(table)
        let edit = try #require(TableEditing.deleteColumn(in: table, region: region, at: 1))
        #expect(applied(edit, to: table) == """
        | Name |
        | --- |
        | Ada |
        """)
    }

    @Test func deletingTheLastColumnDeletesTheTable() throws {
        let text = "| Name |\n| --- |\n| Ada |\n\nAfter\n"
        let region = try firstRegion(text)
        let edit = try #require(TableEditing.deleteColumn(in: text, region: region, at: 0))
        #expect(applied(edit, to: text) == "\nAfter\n")
    }

    // MARK: - Alignment

    @Test func alignedPadsEveryColumnToItsWidestCell() throws {
        let ragged = "|Name|Role|\n|---|---|\n|Ada|Engineer|"
        let region = try firstRegion(ragged)
        #expect(TableEditing.aligned(region: region, in: ragged) == """
        | Name | Role     |
        | ---- | -------- |
        | Ada  | Engineer |
        """)
    }

    @Test func alignedIsIdempotent() throws {
        let ragged = "|Name|Role|\n|:---|---:|\n|Ada|Engineer|\n|Grace|Admiral|"
        let once = try TableEditing.aligned(region: firstRegion(ragged), in: ragged)
        let twice = try TableEditing.aligned(region: firstRegion(once), in: once)
        #expect(once == twice)
    }

    @Test func alignedKeepsAlignmentMarkers() throws {
        let text = "| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |"
        let aligned = try TableEditing.aligned(region: firstRegion(text), in: text)
        #expect(aligned == """
        | a   | b   | c   |
        | :-- | :-: | --: |
        | 1   | 2   | 3   |
        """)
    }

    @Test func alignEditKeepsTheCaretInItsCell() throws {
        let ragged = "|Name|Role|\n|---|---|\n|Ada|Engineer|"
        let region = try firstRegion(ragged)
        let cursor = try location(of: "Engineer", in: ragged)
        let edit = try #require(
            TableEditing.align(in: ragged, region: region, selection: NSRange(location: cursor, length: 8))
        )
        #expect(selected(edit, in: ragged) == "Engineer")
    }

    @Test func alignEditIsNilForAnAlreadyAlignedTable() throws {
        let region = try firstRegion(table)
        let aligned = TableEditing.aligned(region: region, in: table)
        let clean = try firstRegion(aligned)
        #expect(TableEditing.align(
            in: aligned, region: clean, selection: NSRange(location: 0, length: 0)
        ) == nil)
    }

    @Test func alignOnLeaveShiftsAnOutsideCaret() throws {
        let text = "|a|b|\n|---|---|\n|1|2|\n\ntail"
        let tail = try location(of: "tail", in: text)
        let edit = try #require(
            TableEditing.alignEdit(in: text, anchoredAt: 0, selection: NSRange(location: tail, length: 0))
        )
        let updated = applied(edit, to: text) as NSString
        #expect(updated.substring(from: edit.selection.location) == "tail")
    }

    // MARK: - Command path

    @Test func tableCommandsAreNoOpsOutsideTables() {
        let text = "Plain paragraph.\n\n- [ ] a task\n"
        let selection = NSRange(location: 4, length: 0)
        for command: EditorCommand in [
            .tableInsertRow, .tableInsertColumn, .tableDeleteRow, .tableDeleteColumn, .tableAlign,
        ] {
            #expect(MarkdownEditing.apply(command, to: text, selection: selection) == nil)
        }
    }

    @Test func tableCommandsRunThroughMarkdownEditing() throws {
        let cursor = try location(of: "Ada", in: table)
        let edit = try #require(MarkdownEditing.apply(
            .tableInsertRow, to: table, selection: NSRange(location: cursor, length: 0)
        ))
        #expect(applied(edit, to: table) == table + "\n|  |  |")
    }
}

#if canImport(AppKit)
    import AppKit
    import SwiftUI

    /// The key path itself, through a live NSTextView + Coordinator — the
    /// pure logic above cannot prove that `doCommandBy` routes Tab/Return
    /// into tables while leaving list typing alone.
    @MainActor
    struct TableEditorKeyTests {
        private final class Storage {
            var text = ""
        }

        private let table = """
        | Name | Role |
        | --- | --- |
        | Ada | Engineer |
        """

        private func editor(_ text: String) -> (NSTextView, MarkdownEditor.Coordinator) {
            let storage = Storage()
            storage.text = text
            let binding = Binding(get: { storage.text }, set: { storage.text = $0 })
            let coordinator = MarkdownEditor.Coordinator(text: binding, theme: .default)
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            textView.delegate = coordinator
            textView.allowsUndo = true
            textView.string = text
            return (textView, coordinator)
        }

        private func location(of needle: String, in text: String) -> Int {
            (text as NSString).range(of: needle).location
        }

        @Test func tabSelectsTheNextCell() {
            let (textView, coordinator) = editor(table)
            textView.setSelectedRange(NSRange(location: location(of: "Name", in: table), length: 4))
            let handled = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))
            #expect(handled)
            #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "Role")
        }

        @Test func shiftTabSelectsThePreviousCell() {
            let (textView, coordinator) = editor(table)
            textView.setSelectedRange(NSRange(location: location(of: "Ada", in: table), length: 3))
            let handled = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
            #expect(handled)
            #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "Role")
        }

        @Test func tabInTheLastCellGrowsTheTable() {
            let (textView, coordinator) = editor(table)
            textView.setSelectedRange(NSRange(location: location(of: "Engineer", in: table), length: 8))
            #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
            #expect(textView.string == table + "\n|  |  |")
        }

        @Test func returnInATableAddsARowBelow() {
            let (textView, coordinator) = editor(table)
            textView.setSelectedRange(NSRange(location: location(of: "Ada", in: table) + 3, length: 0))
            #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(textView.string == table + "\n|  |  |")
        }

        @Test func listTypingSurvivesTheTableInterception() {
            let text = "- [ ] first\n"
            let (textView, coordinator) = editor(text)
            textView.setSelectedRange(NSRange(location: 11, length: 0))
            #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(textView.string == "- [ ] first\n- [ ] \n")

            textView.setSelectedRange(NSRange(location: 3, length: 0))
            #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
            #expect(textView.string.hasPrefix("  - [ ] first"))
        }

        @Test func plainProseKeepsSystemTabAndReturn() {
            let (textView, coordinator) = editor("just prose\n")
            textView.setSelectedRange(NSRange(location: 4, length: 0))
            #expect(!coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
            #expect(!coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(textView.string == "just prose\n")
        }
    }
#endif

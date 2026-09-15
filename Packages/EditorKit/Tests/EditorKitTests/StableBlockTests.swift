@testable import EditorKit
import Foundation
import MarkdownKit
import Testing

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Tables and frontmatter must not change shape when the caret enters them.
/// These tests hold the attribute side of that contract: one rendering in
/// both caret states, only colors allowed to differ.
@Suite(.serialized) @MainActor struct StableBlockAttributeTests {
    private let theme = MarkdownTheme.default

    private let table = """
    intro line

    | Name | Role     |
    | ---- | -------- |
    | Ada  | Engineer |

    tail line
    """

    private let note = """
    ---
    title: Example Note
    status: active
    ---

    body paragraph

    tail line
    """

    /// Runs one live-preview pass with the caret paragraph containing
    /// `caretIn` (nil = source mode, all markers visible).
    private func styled(_ text: String, caretIn: String?) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let ns = text as NSString
        let cursor = caretIn.map { needle -> NSRange in
            ns.paragraphRange(for: ns.range(of: needle))
        }
        MarkdownHighlighter.highlight(
            storage, theme: theme, reveal: cursor.map { RevealScope.at($0, in: text) }
        )
        return storage
    }

    /// Source mode: no reveal range at all, so nothing is hidden or styled
    /// as a stable block.
    private func sourceMode(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        MarkdownHighlighter.highlight(storage, theme: theme, reveal: nil)
        return storage
    }

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private func font(_ storage: NSTextStorage, at offset: Int) -> PlatformFont? {
        storage.attribute(.font, at: offset, effectiveRange: nil) as? PlatformFont
    }

    private func color(_ storage: NSTextStorage, at offset: Int) -> PlatformColor? {
        storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? PlatformColor
    }

    /// A comparable snapshot of every attribute run in `range` — font name,
    /// point size, and color — for "identical in both states" assertions.
    private func runs(_ storage: NSTextStorage, in range: NSRange) -> [String] {
        var snapshot: [String] = []
        storage.enumerateAttributes(in: range, options: []) { attributes, run, _ in
            let font = attributes[.font] as? PlatformFont
            let color = attributes[.foregroundColor] as? PlatformColor
            snapshot.append(
                "\(run.location)+\(run.length) "
                    + "\(font?.fontName ?? "-")@\(font?.pointSize ?? 0) "
                    + "\(color?.description ?? "-")"
            )
        }
        return snapshot
    }

    /// Same as `runs` but ignoring color — the one thing allowed to differ.
    private func metrics(_ storage: NSTextStorage, in range: NSRange) -> [String] {
        var snapshot: [String] = []
        storage.enumerateAttribute(.font, in: range, options: []) { value, run, _ in
            let font = value as? PlatformFont
            snapshot.append("\(run.location)+\(run.length) \(font?.pointSize ?? 0)")
        }
        return snapshot
    }

    // MARK: - Tables

    @Test func tableLinesAreMonospacedWithTheCaretOutside() {
        let storage = styled(table, caretIn: "intro line")
        let cell = range(of: "Engineer", in: table).location
        #expect(font(storage, at: cell)?.pointSize == theme.tableFont.pointSize)
        #expect(font(storage, at: cell)?.fontName == theme.tableFont.fontName)
    }

    @Test func tableLinesAreMonospacedWithTheCaretInside() {
        let storage = styled(table, caretIn: "Ada")
        let cell = range(of: "Engineer", in: table).location
        #expect(font(storage, at: cell)?.fontName == theme.tableFont.fontName)
    }

    @Test func tableAttributeRunsAreIdenticalInsideAndOutside() {
        let tableRange = NSRange(
            location: range(of: "| Name", in: table).location,
            length: NSMaxRange(range(of: "| Ada  | Engineer |", in: table))
                - range(of: "| Name", in: table).location
        )
        let outside = runs(styled(table, caretIn: "intro line"), in: tableRange)
        let inside = runs(styled(table, caretIn: "Ada"), in: tableRange)
        #expect(outside == inside)
        #expect(!outside.isEmpty)
    }

    @Test func pipesAreDimmedNeverClearedInBothStates() {
        for caret in ["intro line", "Ada"] {
            let storage = styled(table, caretIn: caret)
            let pipe = range(of: "| Ada", in: table).location
            let pipeColor = color(storage, at: pipe)
            #expect(pipeColor == theme.tableSeparatorColor)
            #expect(pipeColor != PlatformColor.clear)
            // Full size: a collapsed pipe would take the row's height with it.
            #expect(font(storage, at: pipe)?.pointSize == theme.tableFont.pointSize)
        }
    }

    @Test func separatorRowDashesStayVisibleAtFullSize() {
        for caret in ["intro line", "Ada"] {
            let storage = styled(table, caretIn: caret)
            let dash = range(of: "----", in: table).location
            #expect(color(storage, at: dash) == theme.tableSeparatorColor)
            #expect(font(storage, at: dash)?.pointSize == theme.tableFont.pointSize)
        }
    }

    @Test func markersInsideACellKeepTheirWidthOffCaret() {
        let marked = """
        intro line

        | Name     | Role     |
        | -------- | -------- |
        | **Ada**  | Engineer |
        """
        let storage = styled(marked, caretIn: "intro line")
        let stars = range(of: "**Ada", in: marked).location
        // Hidden markers would collapse to 0.01pt and misalign the columns.
        #expect(font(storage, at: stars)?.pointSize == theme.tableFont.pointSize)
    }

    @Test func sourceModeLeavesTableLinesPlain() {
        let storage = sourceMode(table)
        let pipe = range(of: "| Ada", in: table).location
        #expect(font(storage, at: pipe)?.fontName == theme.baseFont.fontName)
        #expect(color(storage, at: pipe) != theme.tableSeparatorColor)
    }

    // MARK: - Frontmatter

    @Test func frontmatterKeepsItsFontSizeInsideAndOutside() throws {
        let block = try #require(FrontmatterStyling.blockRange(in: note))
        let outside = metrics(styled(note, caretIn: "body paragraph"), in: block)
        let inside = metrics(styled(note, caretIn: "title: Example"), in: block)
        #expect(outside == inside)
        #expect(!outside.isEmpty)
    }

    @Test func frontmatterOnlyChangesColorWhenTheCaretEnters() {
        let value = range(of: "Example Note", in: note).location
        let outside = styled(note, caretIn: "body paragraph")
        let inside = styled(note, caretIn: "title: Example")
        #expect(font(outside, at: value)?.pointSize == theme.frontmatterFont.pointSize)
        #expect(font(inside, at: value)?.pointSize == theme.frontmatterFont.pointSize)
        #expect(color(outside, at: value) == theme.focusDimColor)
        #expect(color(inside, at: value) == theme.secondaryColor)
    }

    @Test func frontmatterFencesAreDimmedNotCollapsed() {
        for caret in ["body paragraph", "title: Example"] {
            let storage = styled(note, caretIn: caret)
            // Both fences: the opening one (offset 0) and the closing one.
            let closing = range(of: "---\n\nbody", in: note).location
            for offset in [0, closing] {
                #expect(font(storage, at: offset)?.pointSize == theme.frontmatterFont.pointSize)
                #expect(color(storage, at: offset) != PlatformColor.clear)
            }
        }
    }

    @Test func frontmatterKeysKeepTheBodyPointSize() {
        let storage = styled(note, caretIn: "body paragraph")
        let key = range(of: "status", in: note).location
        #expect(font(storage, at: key)?.pointSize == theme.frontmatterFont.pointSize)
        #expect(font(storage, at: key)?.fontName == theme.frontmatterKeyFont.fontName)
    }

    @Test func frontmatterNeverCollapsesToAHairline() throws {
        let storage = styled(note, caretIn: "body paragraph")
        let block = try #require(FrontmatterStyling.blockRange(in: note))
        storage.enumerateAttribute(.font, in: block, options: []) { value, _, _ in
            #expect(((value as? PlatformFont)?.pointSize ?? 0) > 1)
        }
    }

    @Test func sourceModeLeavesFrontmatterPlain() {
        let storage = sourceMode(note)
        let value = range(of: "Example Note", in: note).location
        #expect(font(storage, at: value)?.fontName != theme.frontmatterFont.fontName)
    }

    @Test func aNoteWithoutFrontmatterIsUnaffected() {
        let plain = "# Title\n\nbody paragraph\n"
        #expect(FrontmatterStyling.blockRange(in: plain) == nil)
        let storage = styled(plain, caretIn: "body paragraph")
        let body = range(of: "body", in: plain).location
        #expect(font(storage, at: body)?.fontName == theme.baseFont.fontName)
    }

    /// A locked note is frontmatter + an encrypted body blob: the card must
    /// cover the frontmatter lines only.
    @Test func lockedNoteCardCoversTheFrontmatterLinesOnly() throws {
        let locked = """
        ---
        locked: true
        ---

        U2FsdGVkX1+ciphertextblob==
        """
        let block = try #require(FrontmatterStyling.blockRange(in: locked))
        let storage = styled(locked, caretIn: "locked: true")
        let cipher = range(of: "U2FsdGVkX1", in: locked).location
        #expect(cipher >= NSMaxRange(block))
        #expect(font(storage, at: cipher)?.fontName != theme.frontmatterFont.fontName)
        #expect(font(storage, at: range(of: "locked", in: locked).location)?.pointSize
            == theme.frontmatterFont.pointSize)
    }
}

#if canImport(AppKit)
    import SwiftUI

    /// The layout side of the contract, through a live NSTextView + the real
    /// coordinator (pattern: TableEditorKeyTests). Attribute equality is not
    /// enough — what the user sees move is the laid-out height.
    @Suite(.serialized) @MainActor struct StableBlockLayoutTests {
        private final class Box {
            var text = ""
        }

        private let note = """
        ---
        title: Example Note
        status: active
        ---

        body paragraph

        | Name | Role     |
        | ---- | -------- |
        | Ada  | Engineer |

        tail line
        """

        private func editor(_ text: String) -> (MarkdownTextView, MarkdownEditor.Coordinator) {
            let box = Box()
            box.text = text
            let binding = Binding(get: { box.text }, set: { box.text = $0 })
            let coordinator = MarkdownEditor.Coordinator(text: binding, theme: .default)
            let textView = MarkdownTextView.makeTextKit2()
            textView.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
            textView.textContainer?.size = NSSize(
                width: 520, height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.delegate = coordinator
            textView.textContentStorage?.delegate = coordinator
            textView.textLayoutManager?.delegate = coordinator
            textView.string = text
            return (textView, coordinator)
        }

        /// Laid-out height of the fragments covering `range`.
        private func height(of range: NSRange, in textView: NSTextView) -> CGFloat {
            guard let layout = textView.textLayoutManager,
                  let content = layout.textContentManager,
                  let start = content.location(
                      content.documentRange.location, offsetBy: range.location
                  ),
                  let end = content.location(
                      content.documentRange.location, offsetBy: NSMaxRange(range)
                  )
            else { return 0 }
            layout.ensureLayout(for: content.documentRange)
            var total: CGFloat = 0
            layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                guard fragment.rangeInElement.location.compare(end) == .orderedAscending
                else { return false }
                total += fragment.layoutFragmentFrame.height
                return true
            }
            return total
        }

        private func height(
            of range: NSRange, caretIn needle: String, text: String
        ) -> CGFloat {
            let (textView, coordinator) = editor(text)
            let caret = (text as NSString).range(of: needle)
            textView.setSelectedRange(NSRange(location: caret.location, length: 0))
            coordinator.restyle(textView)
            return height(of: range, in: textView)
        }

        private var tableRange: NSRange {
            let ns = note as NSString
            let start = ns.range(of: "| Name").location
            return NSRange(
                location: start,
                length: NSMaxRange(ns.range(of: "| Ada  | Engineer |")) - start
            )
        }

        @Test func tableHeightIsTheSameWithTheCaretOutsideAndInside() {
            let outside = height(of: tableRange, caretIn: "body paragraph", text: note)
            let inside = height(of: tableRange, caretIn: "Ada", text: note)
            #expect(outside > 0)
            #expect(abs(outside - inside) < 0.01)
        }

        @Test func frontmatterHeightIsTheSameWithTheCaretOutsideAndInside() throws {
            let block = try #require(FrontmatterStyling.blockRange(in: note))
            let outside = height(of: block, caretIn: "body paragraph", text: note)
            let inside = height(of: block, caretIn: "title: Example", text: note)
            #expect(outside > 0)
            #expect(abs(outside - inside) < 0.01)
        }

        /// Nothing below the blocks may shift either.
        @Test func theWholeNoteKeepsItsHeightAcrossCaretMoves() {
            let full = NSRange(location: 0, length: (note as NSString).length)
            let inProse = height(of: full, caretIn: "body paragraph", text: note)
            let inTable = height(of: full, caretIn: "Ada", text: note)
            let inFrontmatter = height(of: full, caretIn: "title: Example", text: note)
            #expect(inProse > 0)
            #expect(abs(inProse - inTable) < 0.01)
            #expect(abs(inProse - inFrontmatter) < 0.01)
        }

        /// The fragment classes the delegate hands back — the grid and the
        /// card must be chosen in BOTH caret states.
        @Test func theGridAndCardFragmentsAreChosenInBothCaretStates() {
            for caret in ["body paragraph", "Ada", "title: Example"] {
                let (textView, coordinator) = editor(note)
                let location = (note as NSString).range(of: caret).location
                textView.setSelectedRange(NSRange(location: location, length: 0))
                coordinator.restyle(textView)
                #expect(fragmentClass(at: tableRange.location, in: textView)
                    == "TableRowLayoutFragment")
                #expect(fragmentClass(at: 0, in: textView) == "FrontmatterLayoutFragment")
            }
        }

        private func fragmentClass(at offset: Int, in textView: NSTextView) -> String {
            guard let layout = textView.textLayoutManager,
                  let content = layout.textContentManager,
                  let location = content.location(content.documentRange.location, offsetBy: offset)
            else { return "-" }
            layout.ensureLayout(for: content.documentRange)
            guard let fragment = layout.textLayoutFragment(for: location) else { return "-" }
            return String(describing: type(of: fragment))
        }
    }
#endif

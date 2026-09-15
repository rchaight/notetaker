#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif
@testable import EditorKit
import Foundation
import MarkdownKit
import SwiftUI
import Testing

// Live Preview's caret path: Typora-style narrow reveal, and the
// equivalence invariant that lets a caret move skip the parse —
// `full restyle at B` == `full restyle at A` + `updateReveal(A → B)`.
//
// @MainActor like every AppKit-touching suite here: the fixtures carry
// NSFont attribute values, and enumerating them on Swift Testing's
// cooperative threads segfaulted intermittently (production always runs
// the highlighter on the main thread).

// MARK: - Shared helpers

@MainActor
private func highlighted(
    _ text: String, selection: NSRange, folds: [NSRange] = [], dim: NSRange? = nil
) -> NSTextStorage {
    let storage = NSTextStorage(string: text)
    MarkdownHighlighter.highlight(
        storage,
        reveal: RevealScope.at(selection, in: text),
        dimOutside: dim,
        foldRanges: folds
    )
    return storage
}

@MainActor
private func isVisible(_ storage: NSTextStorage, at offset: Int) -> Bool {
    let font = storage.attribute(.font, at: offset, effectiveRange: nil) as? PlatformFont
    return (font?.pointSize ?? 0) > 1
}

private func offset(of needle: String, in text: String) -> Int {
    (text as NSString).range(of: needle).location
}

/// Caret in the middle of `needle` — the natural "clicked into it" case.
private func caretInside(_ needle: String, of text: String) -> NSRange {
    let range = (text as NSString).range(of: needle)
    return NSRange(location: range.location + range.length / 2, length: 0)
}

// MARK: - Narrow reveal

@MainActor
struct NarrowRevealTests {
    private let twoBolds = "**one** plain **two**\n"

    @Test func caretInsideBoldRevealsOnlyThatPair() {
        let storage = highlighted(twoBolds, selection: caretInside("one", of: twoBolds))
        #expect(isVisible(storage, at: 0), "the touched span's opening ** must reveal")
        #expect(isVisible(storage, at: 5), "...and its closing **")
        #expect(!isVisible(storage, at: offset(of: "**two**", in: twoBolds)), "the other span stays hidden")
    }

    @Test func caretInPlainTextBetweenSpansRevealsNeither() {
        let storage = highlighted(twoBolds, selection: caretInside("plain", of: twoBolds))
        #expect(!isVisible(storage, at: 0))
        #expect(!isVisible(storage, at: offset(of: "**two**", in: twoBolds)))
    }

    @Test func caretTouchingASpanEdgeRevealsIt() {
        // Caret parked immediately after "**one**" — Typora opens the span
        // you are about to edit, but not the one further along the line.
        let storage = highlighted(twoBolds, selection: NSRange(location: 7, length: 0))
        #expect(isVisible(storage, at: 0))
        #expect(!isVisible(storage, at: offset(of: "**two**", in: twoBolds)))
    }

    @Test func selectionAcrossTwoSpansRevealsBoth() {
        let start = offset(of: "one", in: twoBolds)
        let end = offset(of: "two", in: twoBolds)
        let storage = highlighted(twoBolds, selection: NSRange(location: start, length: end - start))
        #expect(isVisible(storage, at: 0))
        #expect(isVisible(storage, at: offset(of: "**two**", in: twoBolds)))
    }

    @Test func caretOnAHeadingLineRevealsTheHashesOnly() {
        let text = "## Section\n\nbody **bold** here\n"
        let storage = highlighted(text, selection: caretInside("Section", of: text))
        #expect(isVisible(storage, at: 0), "heading hashes reveal with the caret's line")
        #expect(!isVisible(storage, at: offset(of: "**bold**", in: text)), "inline span on another line stays hidden")
    }

    @Test func caretInALinkRevealsItsPlumbing() {
        let text = "see [docs](https://example.com) and **bold**\n"
        let storage = highlighted(text, selection: caretInside("docs", of: text))
        #expect(isVisible(storage, at: offset(of: "[docs]", in: text)), "the opening bracket reveals")
        #expect(isVisible(storage, at: offset(of: "](https", in: text)), "and the destination plumbing")
        #expect(!isVisible(storage, at: offset(of: "**bold**", in: text)))
    }

    @Test func caretInACodeSpanRevealsItsBackticks() {
        let text = "use `run()` and **bold**\n"
        let storage = highlighted(text, selection: caretInside("run", of: text))
        #expect(isVisible(storage, at: offset(of: "`run()`", in: text)))
        #expect(!isVisible(storage, at: offset(of: "**bold**", in: text)))
    }

    @Test func caretInAStrikethroughRevealsItsTildes() {
        let text = "~~gone~~ and *lean* text\n"
        let storage = highlighted(text, selection: caretInside("gone", of: text))
        #expect(isVisible(storage, at: 0))
        #expect(!isVisible(storage, at: offset(of: "*lean*", in: text)))
    }

    @Test func listLineRevealsTheTouchedSpanAndKeepsItsBullet() {
        let text = "- item **bold** and *lean*\n"
        let storage = highlighted(text, selection: caretInside("bold", of: text))
        #expect(isVisible(storage, at: 0), "the bullet is a glyph, never hidden")
        #expect(isVisible(storage, at: offset(of: "**bold**", in: text)))
        #expect(
            !isVisible(storage, at: offset(of: "*lean*", in: text)),
            "the untouched span on the same line stays hidden"
        )
    }

    @Test func blockquotePrefixRevealsOnlyOnTheCaretsLine() {
        let text = "> first line\n> second **b** line\n"
        let storage = highlighted(text, selection: caretInside("second", of: text))
        #expect(!isVisible(storage, at: 0), "the other line's \"> \" stays hidden")
        #expect(isVisible(storage, at: offset(of: "> second", in: text)), "the caret line's \"> \" reveals")
        #expect(!isVisible(storage, at: offset(of: "**b**", in: text)), "an untouched inline span stays hidden")
    }

    @Test func wikilinkRevealsOnlyWhenTouched() {
        let text = "link [[Project Plan]] and ==marked== text\n"
        let inLink = highlighted(text, selection: caretInside("Project", of: text))
        #expect(isVisible(inLink, at: offset(of: "[[Project", in: text)))
        #expect(!isVisible(inLink, at: offset(of: "==marked==", in: text)))
        let inMark = highlighted(text, selection: caretInside("marked", of: text))
        #expect(!isVisible(inMark, at: offset(of: "[[Project", in: text)))
        #expect(isVisible(inMark, at: offset(of: "==marked==", in: text)))
    }

    @Test func sourceModeRevealsEverything() {
        let storage = NSTextStorage(string: twoBolds)
        MarkdownHighlighter.highlight(storage, reveal: nil)
        #expect(isVisible(storage, at: 0))
        #expect(isVisible(storage, at: offset(of: "**two**", in: twoBolds)))
    }

    @Test func revealedSpansNameOnlyTheTouchedSpan() {
        let styled = MarkdownStyler.styleRanges(in: twoBolds)
        let groups = SyntaxMarkers.markerGroups(in: twoBolds, styled: styled)
        let scope = RevealScope.at(caretInside("one", of: twoBolds), in: twoBolds)
        #expect(scope.revealedSpans(in: groups) == [NSRange(location: 0, length: 7)])
    }
}

// MARK: - Equivalence invariant

/// Every construct the highlighter treats specially: headings, inline
/// spans, lists/tasks, quotes, code fences, rules, tables, frontmatter.
private let revealFixtures: [String] = [
    // Fold + table: the stable-block pass must stay inside the update
    // window or a folded table re-inflates on any caret move.
    "# Top\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n# Next\n\nplain **bold** tail\n",
    // Inline marker inside a cell: the marker group path re-asserts it.
    "| Name | Note |\n| --- | --- |\n| Ada | has **bold** cell |\n\nafter *lean*\n",
    "**one** plain **two**\n\nsecond *line* here\n",
    "## Section\n\nbody with `code` and [docs](https://example.com)\n\n### Sub\n\ntail\n",
    "- item **bold** and *lean*\n- [ ] task with #tag and @person\n  - nested ==marked==\n",
    "> quoted **wisdom**\n> more > nested\n\nplain tail\n",
    "```swift\nlet a = 1\n```\n\nafter the fence **b**\n",
    "above\n\n---\n\nbelow *lean*\n",
    "intro\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nafter **bold**\n",
    "---\nfavorite: true\n---\n# Body\ntext with ~~strike~~\n",
    "![alt](pic.png)\n\ntext [[Wiki Link]] tail\n",
]

/// Per-character attribute description — stricter than comparing runs, and
/// immune to how the storage happens to coalesce them.
@MainActor
private func attributeDump(_ storage: NSTextStorage) -> [String] {
    (0 ..< storage.length).map { index in
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        return attributes.keys.map(\.rawValue).sorted().map { key in
            "\(key)=\(describe(attributes[NSAttributedString.Key(key)]))"
        }.joined(separator: "|")
    }
}

@MainActor
private func describe(_ value: Any?) -> String {
    switch value {
    case let font as PlatformFont:
        "\(font.fontName)@\(font.pointSize)"
    case let url as URL:
        url.absoluteString
    case let style as NSParagraphStyle:
        [
            style.firstLineHeadIndent, style.headIndent, style.tailIndent,
            style.paragraphSpacing, style.paragraphSpacingBefore,
            style.lineHeightMultiple, style.minimumLineHeight, style.maximumLineHeight,
        ].map { "\($0)" }.joined(separator: ",") + ",\(style.alignment.rawValue)"
    default:
        String(describing: value)
    }
}

/// Caret positions worth probing: every marker edge (the interesting
/// transitions) plus an even sweep, capped so the pair matrix stays quick,
/// plus two selections.
private func probeSelections(in text: String) -> [NSRange] {
    let ns = text as NSString
    let styled = MarkdownStyler.styleRanges(in: text)
    var edges = Set<Int>([0, ns.length])
    for group in SyntaxMarkers.markerGroups(in: text, styled: styled) {
        for marker in group.markers {
            edges.insert(marker.location)
            edges.insert(NSMaxRange(marker))
            edges.insert(min(marker.location + 1, ns.length))
        }
    }
    for step in stride(from: 0, to: ns.length, by: max(1, ns.length / 5)) {
        edges.insert(step)
    }
    let sorted = edges.sorted()
    let keep = 8
    let sampled = sorted.count <= keep
        ? sorted
        : (0 ..< keep).map { sorted[$0 * (sorted.count - 1) / (keep - 1)] }
    var selections = sampled.map { NSRange(location: $0, length: 0) }
    if ns.length > 12 {
        selections.append(NSRange(location: 0, length: 12))
        selections.append(NSRange(location: ns.length / 3, length: min(9, ns.length - ns.length / 3)))
    }
    return selections
}

@MainActor
struct RevealEquivalenceTests {
    private func folds(in text: String, styled: [StyledRange]) -> [NSRange] {
        guard let first = HeadingFolding.headings(in: text, styled: styled).first else { return [] }
        return HeadingFolding.foldRanges(foldedKeys: [first.key], in: text, styled: styled)
    }

    /// The core invariant: a caret move handled incrementally is
    /// indistinguishable from a full restyle at the new caret.
    @Test(arguments: revealFixtures)
    func incrementalRevealMatchesFullRestyle(_ text: String) {
        let styled = MarkdownStyler.styleRanges(in: text)
        let groups = SyntaxMarkers.markerGroups(in: text, styled: styled)
        let foldRanges = folds(in: text, styled: styled)
        let selections = probeSelections(in: text)
        var fullDumps: [Int: [String]] = [:]

        func fullDump(_ index: Int) -> [String] {
            if let cached = fullDumps[index] {
                return cached
            }
            let storage = NSTextStorage(string: text)
            MarkdownHighlighter.highlight(
                storage, styled: styled, groups: groups,
                reveal: RevealScope.at(selections[index], in: text), foldRanges: foldRanges
            )
            let dump = attributeDump(storage)
            fullDumps[index] = dump
            return dump
        }

        for (fromIndex, from) in selections.enumerated() {
            for (toIndex, to) in selections.enumerated() where fromIndex != toIndex {
                let scopeA = RevealScope.at(from, in: text)
                let scopeB = RevealScope.at(to, in: text)
                let storage = NSTextStorage(string: text)
                MarkdownHighlighter.highlight(
                    storage, styled: styled, groups: groups, reveal: scopeA, foldRanges: foldRanges
                )
                MarkdownHighlighter.updateReveal(
                    storage, styled: styled, groups: groups,
                    from: scopeA, to: scopeB, foldRanges: foldRanges
                )
                #expect(
                    attributeDump(storage) == fullDump(toIndex),
                    "\(from) → \(to) drifted from a full restyle"
                )
                #expect(storage.string == text, "reveal must never mutate characters")
            }
        }
    }

    /// Chained moves must not accumulate drift either.
    @Test(arguments: revealFixtures)
    func chainedRevealUpdatesStayExact(_ text: String) {
        let styled = MarkdownStyler.styleRanges(in: text)
        let groups = SyntaxMarkers.markerGroups(in: text, styled: styled)
        let selections = probeSelections(in: text)
        let storage = NSTextStorage(string: text)
        var scope = RevealScope.at(selections[0], in: text)
        MarkdownHighlighter.highlight(storage, styled: styled, groups: groups, reveal: scope)
        for selection in selections.dropFirst() {
            let next = RevealScope.at(selection, in: text)
            MarkdownHighlighter.updateReveal(
                storage, styled: styled, groups: groups, from: scope, to: next
            )
            scope = next
        }
        let full = NSTextStorage(string: text)
        MarkdownHighlighter.highlight(full, styled: styled, groups: groups, reveal: scope)
        #expect(attributeDump(storage) == attributeDump(full))
    }

    /// Focus dim survives a windowed re-application (the dim region itself
    /// is unchanged — focus mode full-restyles when it moves).
    @Test func revealUpdateKeepsAnUnchangedFocusDim() {
        let text = "intro **bold** here\n\nsecond *lean* line\n"
        let styled = MarkdownStyler.styleRanges(in: text)
        let groups = SyntaxMarkers.markerGroups(in: text, styled: styled)
        let dim = (text as NSString).paragraphRange(for: NSRange(location: 0, length: 1))
        let scopeA = RevealScope.at(caretInside("bold", of: text), in: text)
        let scopeB = RevealScope.at(caretInside("intro", of: text), in: text)
        let storage = NSTextStorage(string: text)
        MarkdownHighlighter.highlight(
            storage, styled: styled, groups: groups, reveal: scopeA, dimOutside: dim
        )
        MarkdownHighlighter.updateReveal(
            storage, styled: styled, groups: groups, from: scopeA, to: scopeB, dimOutside: dim
        )
        let full = NSTextStorage(string: text)
        MarkdownHighlighter.highlight(
            full, styled: styled, groups: groups, reveal: scopeB, dimOutside: dim
        )
        #expect(attributeDump(storage) == attributeDump(full))
    }

    @Test func aCaretMoveThatChangesNothingDoesNoWork() {
        let text = "plain words with no syntax at all in this line\n"
        let styled = MarkdownStyler.styleRanges(in: text)
        let groups = SyntaxMarkers.markerGroups(in: text, styled: styled)
        let scopeA = RevealScope.at(NSRange(location: 2, length: 0), in: text)
        let scopeB = RevealScope.at(NSRange(location: 20, length: 0), in: text)
        #expect(MarkdownHighlighter.revealDelta(
            in: text, styled: styled, groups: groups, from: scopeA, to: scopeB
        ).isEmpty)
        let storage = NSTextStorage(string: text)
        MarkdownHighlighter.highlight(storage, styled: styled, groups: groups, reveal: scopeA)
        let touched = MarkdownHighlighter.updateReveal(
            storage, styled: styled, groups: groups, from: scopeA, to: scopeB
        )
        #expect(!touched, "nothing flipped, so nothing should be re-styled")
    }

    @Test func enteringASpanFlipsOnlyThatSpansMarkers() {
        let text = "**one** plain **two**\n"
        let styled = MarkdownStyler.styleRanges(in: text)
        let groups = SyntaxMarkers.markerGroups(in: text, styled: styled)
        let delta = MarkdownHighlighter.revealDelta(
            in: text, styled: styled, groups: groups,
            from: RevealScope.at(caretInside("plain", of: text), in: text),
            to: RevealScope.at(caretInside("one", of: text), in: text)
        )
        #expect(delta.sorted { $0.location < $1.location } == [
            NSRange(location: 0, length: 2), NSRange(location: 5, length: 2),
        ])
    }
}

// MARK: - The caret path never re-parses

#if canImport(AppKit)
    @MainActor
    struct CaretOnlyRestyleTests {
        private final class Storage {
            var text = ""
        }

        private func editor(_ text: String) -> (NSTextView, MarkdownEditor.Coordinator) {
            let storage = Storage()
            storage.text = text
            let binding = Binding(get: { storage.text }, set: { storage.text = $0 })
            let coordinator = MarkdownEditor.Coordinator(text: binding, theme: .default)
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            textView.delegate = coordinator
            textView.string = text
            coordinator.livePreview = true
            coordinator.restyle(textView)
            return (textView, coordinator)
        }

        private func selectionChanged(_ textView: NSTextView, _ coordinator: MarkdownEditor.Coordinator) {
            coordinator.textViewDidChangeSelection(
                Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
            )
        }

        @Test func sourceModeWithFocusStaysFullyRevealed() throws {
            // Critic-caught (round 2): the Focus-mode same-paragraph path
            // must not build a Live Preview scope while in Source mode.
            let text = "---\nfavorite: true\n---\n**one** plain **two**\n\nsecond *lean*\n"
            let (textView, coordinator) = editor(text)
            coordinator.livePreview = false
            coordinator.focusMode = true
            textView.setSelectedRange(caretInside("one", of: text))
            coordinator.restyle(textView)
            let storage = try #require(textView.textStorage)
            let fmOffset = offset(of: "favorite", in: text)
            let fmFontBefore = storage.attribute(.font, at: fmOffset, effectiveRange: nil) as? PlatformFont
            #expect(isVisible(storage, at: offset(of: "**two**", in: text)))

            textView.setSelectedRange(caretInside("plain", of: text))
            selectionChanged(textView, coordinator)
            #expect(isVisible(storage, at: offset(of: "**two**", in: text)), "source mode shows every marker")
            #expect(isVisible(storage, at: offset(of: "*lean*", in: text)))
            let fmFontAfter = storage.attribute(.font, at: fmOffset, effectiveRange: nil) as? PlatformFont
            #expect(fmFontAfter == fmFontBefore, "no frontmatter card styling in source mode")
        }

        @Test func focusModeKeepsTheNarrowRevealAlive() throws {
            // Critic-caught: Focus mode early-returned on same-paragraph
            // caret moves, freezing the reveal at whatever the caret touched
            // when the paragraph was entered.
            let text = "plain start **bold** and *lean* end\n\nother paragraph\n"
            let (textView, coordinator) = editor(text)
            coordinator.focusMode = true
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.restyle(textView)
            let storage = try #require(textView.textStorage)
            #expect(!isVisible(storage, at: offset(of: "**bold**", in: text)))

            textView.setSelectedRange(caretInside("bold", of: text))
            selectionChanged(textView, coordinator)
            #expect(
                isVisible(storage, at: offset(of: "**bold**", in: text)),
                "a same-paragraph move must reveal the touched span in Focus mode"
            )
            #expect(!isVisible(storage, at: offset(of: "*lean*", in: text)))
        }

        #if DEBUG
            @Test func caretMoveNeverReParses() throws {
                let text = "# Title\n\nsome **bold** and *lean* text\n\n| a | b |\n| - | - |\n"
                let (textView, coordinator) = editor(text)
                let storage = try #require(textView.textStorage)
                let before = MarkdownStyler.parseCount.load(ordering: .relaxed)

                textView.setSelectedRange(caretInside("bold", of: text))
                selectionChanged(textView, coordinator)
                #expect(
                    MarkdownStyler.parseCount.load(ordering: .relaxed) == before,
                    "a caret move must reuse the cached parse"
                )
                #expect(isVisible(storage, at: offset(of: "**bold**", in: text)), "the touched span revealed")
                #expect(!isVisible(storage, at: offset(of: "*lean*", in: text)))

                textView.setSelectedRange(caretInside("lean", of: text))
                selectionChanged(textView, coordinator)
                #expect(MarkdownStyler.parseCount.load(ordering: .relaxed) == before)
                #expect(!isVisible(storage, at: offset(of: "**bold**", in: text)), "the old span closed again")
                #expect(isVisible(storage, at: offset(of: "*lean*", in: text)))
            }

            @Test func aTextChangeStillReParses() {
                let text = "some **bold** text\n"
                let (textView, coordinator) = editor(text)
                let before = MarkdownStyler.parseCount.load(ordering: .relaxed)
                // AppKit hands the insertion to the delegate itself, so this
                // is the real keystroke path: exactly one parse. The caret
                // notification the insertion also fires must not add a
                // second one.
                textView.insertText("more ", replacementRange: NSRange(location: 0, length: 0))
                #expect(MarkdownStyler.parseCount.load(ordering: .relaxed) - before == 1)
                #expect(coordinator.text.wrappedValue == "more some **bold** text\n")
            }
        #endif

        /// The caret path must reach the same attributes the old
        /// whole-document restyle produced.
        @Test func caretPathMatchesAFullRestyle() throws {
            let text = "# Title\n\nsome **bold** and *lean* text\n\n> quoted\n"
            let (textView, coordinator) = editor(text)
            let storage = try #require(textView.textStorage)
            textView.setSelectedRange(caretInside("lean", of: text))
            selectionChanged(textView, coordinator)
            let incremental = attributeDump(storage)
            coordinator.restyle(textView)
            #expect(incremental == attributeDump(storage))
        }
    }
#endif

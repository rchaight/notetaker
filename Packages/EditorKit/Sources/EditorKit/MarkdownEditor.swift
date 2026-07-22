import MarkdownKit
import SwiftUI
import TaskEngine

/// TextKit 2 markdown editor with live syntax styling on every keystroke.
/// The underlying storage is always the plain CommonMark source — styling
/// is attributes only, so the file on disk stays valid markdown.
/// Ranges whose appearance depends on cursor position: syntax markers
/// (hidden off-cursor) plus table/thematic-break bodies (rendered clear
/// off-cursor). A cursor transition touching none of these cannot change
/// layout, so the editor skips the whole-document restyle.
@MainActor
func markdownRevealRanges(in text: String, styled: [StyledRange]) -> [NSRange] {
    var ranges = SyntaxMarkers.markerRanges(in: text, styled: styled)
    let frontmatterLength = MarkdownDocument(source: text).bodyUTF16Offset
    if frontmatterLength > 0 {
        ranges.append(NSRange(location: 0, length: frontmatterLength))
    }
    for item in styled {
        switch item.kind {
        case .table, .thematicBreak:
            ranges.append(item.range)
        default:
            continue
        }
    }
    return ranges
}

#if canImport(AppKit)
    import AppKit

    public struct MarkdownEditor: NSViewRepresentable {
        @Binding var text: String
        @Binding var scrollTarget: NSRange?
        @Binding var command: EditorCommandRequest?
        var theme: MarkdownTheme
        var livePreview: Bool
        var focusMode: Bool
        var imageBase: URL?
        var tagCandidates: [String]
        var linkCandidates: [String]
        var findSignal: Int

        public init(
            text: Binding<String>,
            scrollTarget: Binding<NSRange?> = .constant(nil),
            command: Binding<EditorCommandRequest?> = .constant(nil),
            theme: MarkdownTheme = .default,
            livePreview: Bool = true,
            focusMode: Bool = false,
            imageBase: URL? = nil,
            tagCandidates: [String] = [],
            linkCandidates: [String] = [],
            findSignal: Int = 0
        ) {
            _text = text
            _scrollTarget = scrollTarget
            _command = command
            self.theme = theme
            self.livePreview = livePreview
            self.focusMode = focusMode
            self.imageBase = imageBase
            self.tagCandidates = tagCandidates
            self.linkCandidates = linkCandidates
            self.findSignal = findSignal
        }

        /// One cached editor per process: tab switches tear the SwiftUI
        /// view down and rebuilding NSTextView + a full restyle cost a
        /// visible beat (user-reported). Reuse skips both when the text
        /// hasn't changed. A second window (cache occupied) builds fresh.
        @MainActor
        enum SharedEditorCache {
            static var scrollView: NSScrollView?
            static var coordinator: Coordinator?
        }

        public func makeCoordinator() -> Coordinator {
            if let cached = SharedEditorCache.coordinator {
                cached.text = $text
                cached.theme = theme
                return cached
            }
            let coordinator = Coordinator(text: $text, theme: theme)
            SharedEditorCache.coordinator = coordinator
            return coordinator
        }

        public func makeNSView(context: Context) -> NSScrollView {
            if let cached = SharedEditorCache.scrollView,
               cached.superview == nil, cached.window == nil,
               let textView = cached.documentView as? NSTextView,
               context.coordinator === SharedEditorCache.coordinator {
                context.coordinator.livePreview = livePreview
                context.coordinator.focusMode = focusMode
                context.coordinator.imageBase = imageBase
                context.coordinator.tagCandidates = tagCandidates
                context.coordinator.linkCandidates = linkCandidates
                if textView.string != text {
                    textView.string = text
                    context.coordinator.restyle(textView)
                }
                return cached
            }
            let scrollView = NSTextView.scrollableTextView()
            let textView = scrollView.documentView as! NSTextView
            textView.delegate = context.coordinator
            textView.allowsUndo = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            // Apple Writing Tools (proofread/rewrite/summarize) — free on
            // TextKit 2; .complete allows full inline rewrites.
            textView.writingToolsBehavior = .complete
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.drawsBackground = true
            textView.backgroundColor = theme.editorBackground
            scrollView.drawsBackground = false
            textView.insertionPointColor = theme.accentColor
            // Checkbox toggles ride on .link — the system's blue underline
            // must not restyle them (theme attributes already do).
            textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
            textView.selectedTextAttributes = [.backgroundColor: theme.selectionBackground]
            // Hard-wrap to the view: long lines must never widen the
            // window (SwiftUI windows grow to content ideal width).
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
            textView.string = text
            // Display-only glyph rendering (• bullets, ○/● check bubbles).
            textView.textContentStorage?.delegate = context.coordinator
            // Custom fragment drawing (blockquote accent bar).
            textView.textLayoutManager?.delegate = context.coordinator
            context.coordinator.livePreview = livePreview
            context.coordinator.focusMode = focusMode
            context.coordinator.imageBase = imageBase
            context.coordinator.tagCandidates = tagCandidates
            context.coordinator.linkCandidates = linkCandidates
            context.coordinator.restyle(textView)
            if SharedEditorCache.scrollView == nil {
                SharedEditorCache.scrollView = scrollView
            }
            return scrollView
        }

        public func updateNSView(_ scrollView: NSScrollView, context: Context) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            let modeChanged = context.coordinator.livePreview != livePreview
                || context.coordinator.focusMode != focusMode
                || context.coordinator.theme.baseFontSize != theme.baseFontSize
                || context.coordinator.theme.fontDesign != theme.fontDesign
            context.coordinator.theme = theme
            context.coordinator.livePreview = livePreview
            context.coordinator.focusMode = focusMode
            context.coordinator.imageBase = imageBase
            context.coordinator.tagCandidates = tagCandidates
            context.coordinator.linkCandidates = linkCandidates
            if textView.string != text {
                textView.string = text
                context.coordinator.restyle(textView)
            } else if modeChanged {
                context.coordinator.restyle(textView)
            }
            if let target = scrollTarget,
               NSMaxRange(target) <= (textView.string as NSString).length {
                textView.scrollRangeToVisible(target)
                textView.setSelectedRange(NSRange(location: target.location, length: 0))
                Task { @MainActor in scrollTarget = nil }
            }
            // ⌘F: pop the native find bar (one-shot by signal).
            if findSignal != context.coordinator.lastFindSignal {
                context.coordinator.lastFindSignal = findSignal
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.window?.makeFirstResponder(textView)
                textView.performTextFinderAction(item)
            }
            // One-shot by token: text mutation re-enters this method before
            // the async binding clear lands — un-stamped commands loop the
            // main thread forever (44s hang, user-reported).
            if let pending = command, context.coordinator.lastCommandID != pending.id {
                context.coordinator.lastCommandID = pending.id
                if let edit = MarkdownEditing.apply(
                    pending.command, to: textView.string, selection: textView.selectedRange()
                ) {
                    textView.insertText(edit.replacement, replacementRange: edit.range)
                    textView.setSelectedRange(edit.selection)
                }
                Task { @MainActor in command = nil }
            }
        }

        @MainActor
        public final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextContentStorageDelegate,
            @preconcurrency NSTextLayoutManagerDelegate {
            var text: Binding<String>
            var theme: MarkdownTheme
            var livePreview = true
            var focusMode = false
            var imageBase: URL?
            var tagCandidates: [String] = []
            var linkCandidates: [String] = []
            var codeRegions: [CodeCardRegions.Region] = []
            var tableRegions: [TableGrid.Region] = []
            var revealRanges: [NSRange] = []
            var frontmatterLength = 0
            var lastCommandID: UUID?
            var lastFindSignal = 0
            var lastTextLength = 0
            private var lastCursorLine: NSRange?
            private var pendingRestyle: Task<Void, Never>?

            /// Above this size, keystroke restyles are debounced so typing
            /// never waits on a full re-parse (50k words ≈ 150ms debug).
            private static let debounceThresholdUTF16 = 20000

            init(text: Binding<String>, theme: MarkdownTheme) {
                self.text = text
                self.theme = theme
            }

            func restyle(_ textView: NSTextView) {
                guard let storage = textView.textStorage else { return }
                let cursor = cursorParagraph(textView)
                lastCursorLine = cursor
                let styled = MarkdownHighlighter.highlight(
                    storage,
                    theme: theme,
                    hideMarkersOutside: livePreview ? cursor : nil,
                    dimOutside: focusMode ? cursor : nil
                )
                codeRegions = CodeCardRegions.regions(in: textView.string, styled: styled)
                tableRegions = TableGrid.regions(in: textView.string, styled: styled)
                revealRanges = markdownRevealRanges(in: textView.string, styled: styled)
                frontmatterLength = MarkdownDocument(source: textView.string).bodyUTF16Offset
            }

            private func scheduleRestyle(_ textView: NSTextView) {
                pendingRestyle?.cancel()
                guard (textView.string as NSString).length > Self.debounceThresholdUTF16 else {
                    restyle(textView)
                    return
                }
                pendingRestyle = Task { [weak self, weak textView] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self, let textView else { return }
                    restyle(textView)
                }
            }

            private func cursorParagraph(_ textView: NSTextView) -> NSRange {
                let ns = textView.string as NSString
                let selection = textView.selectedRange()
                let location = min(selection.location, ns.length)
                return ns.paragraphRange(for: NSRange(location: location, length: 0))
            }

            public func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                text.wrappedValue = textView.string
                scheduleRestyle(textView)
                // Auto-offer tag/[[link completions while a token is open —
                // but ONLY when we have matching candidates (an empty list
                // lets AppKit substitute its own lexicon), and ONLY on
                // INSERTION: re-triggering on deletion trapped users trying
                // to backspace "#Header" into a heading (user-reported).
                let newLength = (textView.string as NSString).length
                let grew = newLength > lastTextLength
                lastTextLength = newLength
                let selection = textView.selectedRange()
                if grew, selection.length == 0,
                   let match = AutocompleteContext.match(
                       in: textView.string, cursor: selection.location
                   ),
                   hasCandidates(for: match) {
                    textView.complete(nil)
                }
            }

            private func hasCandidates(for match: AutocompleteContext.Match) -> Bool {
                let pool = match.kind == .tag ? tagCandidates : linkCandidates
                return !AutocompleteContext.completionStrings(
                    query: match.query, partialLength: 0, candidates: pool
                ).isEmpty
            }

            public func textView(
                _ textView: NSTextView,
                completions _: [String],
                forPartialWordRange charRange: NSRange,
                indexOfSelectedItem _: UnsafeMutablePointer<Int>?
            ) -> [String] {
                let cursor = textView.selectedRange().location
                guard let match = AutocompleteContext.match(in: textView.string, cursor: cursor)
                else { return [] }
                return switch match.kind {
                case .tag:
                    AutocompleteContext.completionStrings(
                        query: match.query, partialLength: charRange.length,
                        candidates: tagCandidates, substringMatch: true
                    )
                case .wikilink:
                    AutocompleteContext.completionStrings(
                        query: match.query, partialLength: charRange.length,
                        candidates: linkCandidates, appending: "]]"
                    )
                }
            }

            public func textViewDidChangeSelection(_ notification: Notification) {
                guard livePreview || focusMode, let textView = notification.object as? NSTextView else { return }
                let cursor = cursorParagraph(textView)
                guard cursor != lastCursorLine else { return }
                // Full restyle reflows text under the click (markers reveal
                // at full size) — skip it when neither the old nor the new
                // cursor paragraph contains anything hidden (user-reported
                // "erratic jumps" clicking around plain text).
                if focusMode || cursorTransitionAffectsLayout(from: lastCursorLine, to: cursor) {
                    restyle(textView)
                } else {
                    lastCursorLine = cursor
                }
            }

            private func cursorTransitionAffectsLayout(from old: NSRange?, to new: NSRange) -> Bool {
                revealRanges.contains { range in
                    NSIntersectionRange(range, new).length > 0
                        || old.map { NSIntersectionRange(range, $0).length > 0 } ?? false
                }
            }

            public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                let selection = textView.selectedRange()
                func apply(_ edit: EditResult) -> Bool {
                    textView.insertText(edit.replacement, replacementRange: edit.range)
                    textView.setSelectedRange(edit.selection)
                    return true
                }
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)):
                    if let edit = MarkdownEditing.newlineContinuation(in: textView.string, selection: selection) {
                        return apply(edit)
                    }
                case #selector(NSResponder.insertTab(_:)):
                    if let edit = MarkdownEditing.indentListItems(
                        in: textView.string,
                        selection: selection,
                        outdent: false
                    ) {
                        return apply(edit)
                    }
                case #selector(NSResponder.insertBacktab(_:)):
                    if let edit = MarkdownEditing.indentListItems(
                        in: textView.string,
                        selection: selection,
                        outdent: true
                    ) {
                        return apply(edit)
                    }
                default:
                    break
                }
                return false
            }

            public func textContentStorage(
                _ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange
            ) -> NSTextParagraph? {
                guard livePreview,
                      !codeRegions.contains(where: { NSIntersectionRange($0.range, range).length > 0 }),
                      let storage = textContentStorage.textStorage,
                      NSMaxRange(range) <= storage.length,
                      let swapped = ListGlyphSubstitution.substituted(
                          paragraph: storage.attributedSubstring(from: range)
                      )
                else { return nil }
                return NSTextParagraph(attributedString: swapped)
            }

            public func textLayoutManager(
                _ textLayoutManager: NSTextLayoutManager,
                textLayoutFragmentFor _: NSTextLocation,
                in textElement: NSTextElement
            ) -> NSTextLayoutFragment {
                if let contentManager = textLayoutManager.textContentManager,
                   let elementRange = textElement.elementRange {
                    let start = contentManager.offset(
                        from: contentManager.documentRange.location, to: elementRange.location
                    )
                    let end = contentManager.offset(
                        from: contentManager.documentRange.location, to: elementRange.endLocation
                    )
                    let paragraphRange = NSRange(location: start, length: max(end - start, 0))
                    // Frontmatter lines never get decorated fragments (its
                    // "---" fences are not thematic breaks).
                    if start < frontmatterLength {
                        return NSTextLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                    }
                    if let table = tableRegions.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }), let cursorLine = lastCursorLine,
                    NSIntersectionRange(table.range, cursorLine).length == 0,
                    let row = table.rows.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = TableRowLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.cells = row.cells
                        fragment.columns = TableGrid.columnLayout(
                            for: table, headerFont: theme.tableHeaderFont, bodyFont: theme.baseFont
                        )
                        fragment.isSeparator = row.isSeparator
                        fragment.isHeader = row.range == table.rows.first?.range
                        fragment.isFirstRow = fragment.isHeader
                        fragment.isLastRow = row.range == table.rows.last?.range
                        fragment.theme = theme
                        return fragment
                    }
                    if let region = codeRegions.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = CodeCardLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.roundsTop = paragraphRange.location <= region.range.location
                        fragment.roundsBottom = NSMaxRange(paragraphRange) >= NSMaxRange(region.range)
                        fragment.badge = fragment.roundsTop ? region.language : nil
                        fragment.fillColor = theme.surfaceBackground
                        fragment.badgeColor = theme.secondaryColor
                        return fragment
                    }
                }
                if let paragraph = textElement as? NSTextParagraph {
                    let content = paragraph.attributedString.string
                    if BlockquoteDetection.isQuoteParagraph(content) {
                        let fragment = QuoteBarLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.barColor = theme.quoteAccent
                        return fragment
                    }
                    if ThematicBreakDetection.isRuleParagraph(content) {
                        let fragment = RuleLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.lineColor = theme.focusDimColor
                        return fragment
                    }
                    if let source = ImageThumbnails.standaloneImageSource(content) {
                        let fragment = ImageLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.source = source
                        fragment.baseURL = imageBase
                        return fragment
                    }
                }
                return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            }

            public func textView(_ textView: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
                guard let url = link as? URL,
                      let offset = MarkdownHighlighter.toggleOffset(from: url)
                else { return false }
                let range = NSRange(location: offset, length: 3)
                let ns = textView.string as NSString
                guard NSMaxRange(range) <= ns.length,
                      let updated = RecurrenceEngine.completeTask(in: textView.string, tokenRange: range)
                else { return false }
                // Replace just the affected paragraph so undo works and
                // textDidChange fires (binding + restyle).
                let lineRange = ns.paragraphRange(for: range)
                let newLineRange = (updated as NSString)
                    .paragraphRange(for: NSRange(location: lineRange.location, length: 0))
                let newLine = (updated as NSString).substring(with: newLineRange)
                textView.insertText(newLine, replacementRange: lineRange)
                return true
            }
        }
    }

#else
    import UIKit

    public struct MarkdownEditor: UIViewRepresentable {
        @Binding var text: String
        @Binding var scrollTarget: NSRange?
        @Binding var command: EditorCommandRequest?
        var theme: MarkdownTheme
        var livePreview: Bool
        var focusMode: Bool
        var imageBase: URL?
        var tagCandidates: [String]
        var linkCandidates: [String]
        var findSignal: Int

        public init(
            text: Binding<String>,
            scrollTarget: Binding<NSRange?> = .constant(nil),
            command: Binding<EditorCommandRequest?> = .constant(nil),
            theme: MarkdownTheme = .default,
            livePreview: Bool = true,
            focusMode: Bool = false,
            imageBase: URL? = nil,
            tagCandidates: [String] = [],
            linkCandidates: [String] = [],
            findSignal: Int = 0
        ) {
            _text = text
            _scrollTarget = scrollTarget
            _command = command
            self.theme = theme
            self.livePreview = livePreview
            self.focusMode = focusMode
            self.imageBase = imageBase
            self.tagCandidates = tagCandidates
            self.linkCandidates = linkCandidates
            self.findSignal = findSignal
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, theme: theme)
        }

        public func makeUIView(context: Context) -> UITextView {
            // usingTextLayoutManager: TextKit 2 storage/layout.
            let textView = UITextView(usingTextLayoutManager: true)
            textView.delegate = context.coordinator
            textView.autocorrectionType = .default
            textView.smartQuotesType = .no
            textView.smartDashesType = .no
            textView.writingToolsBehavior = .complete
            textView.alwaysBounceVertical = true
            textView.isFindInteractionEnabled = true
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
            textView.backgroundColor = theme.editorBackground
            textView.tintColor = theme.accentColor
            textView.linkTextAttributes = [:]
            textView.text = text
            (textView.textLayoutManager?.textContentManager as? NSTextContentStorage)?
                .delegate = context.coordinator
            textView.textLayoutManager?.delegate = context.coordinator
            // Editable UITextViews don't tap links, so checkbox toggles get a
            // gesture that only fires when the touch lands on a token.
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleCheckboxTap(_:))
            )
            tap.delegate = context.coordinator
            textView.addGestureRecognizer(tap)
            context.coordinator.livePreview = livePreview
            context.coordinator.focusMode = focusMode
            context.coordinator.imageBase = imageBase
            context.coordinator.tagCandidates = tagCandidates
            context.coordinator.linkCandidates = linkCandidates
            context.coordinator.restyle(textView)
            return textView
        }

        public func updateUIView(_ textView: UITextView, context: Context) {
            if findSignal != context.coordinator.lastFindSignal {
                context.coordinator.lastFindSignal = findSignal
                textView.findInteraction?.presentFindNavigator(showingReplace: false)
            }
            let modeChanged = context.coordinator.livePreview != livePreview
                || context.coordinator.focusMode != focusMode
                || context.coordinator.theme.baseFontSize != theme.baseFontSize
                || context.coordinator.theme.fontDesign != theme.fontDesign
            context.coordinator.theme = theme
            context.coordinator.livePreview = livePreview
            context.coordinator.focusMode = focusMode
            context.coordinator.imageBase = imageBase
            context.coordinator.tagCandidates = tagCandidates
            context.coordinator.linkCandidates = linkCandidates
            if textView.text != text {
                textView.text = text
                context.coordinator.restyle(textView)
            } else if modeChanged {
                context.coordinator.restyle(textView)
            }
            if let target = scrollTarget,
               NSMaxRange(target) <= ((textView.text ?? "") as NSString).length {
                textView.scrollRangeToVisible(target)
                textView.selectedRange = NSRange(location: target.location, length: 0)
                Task { @MainActor in scrollTarget = nil }
            }
            if let pending = command, context.coordinator.lastCommandID != pending.id {
                context.coordinator.lastCommandID = pending.id
                let current = textView.text ?? ""
                if let edit = MarkdownEditing.apply(pending.command, to: current, selection: textView.selectedRange) {
                    textView.textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
                    textView.selectedRange = edit.selection
                    context.coordinator.restyle(textView)
                    Task { @MainActor in
                        text = textView.text
                        command = nil
                    }
                } else {
                    Task { @MainActor in command = nil }
                }
            }
        }

        @MainActor
        public final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate,
            @preconcurrency NSTextContentStorageDelegate, @preconcurrency NSTextLayoutManagerDelegate {
            var text: Binding<String>
            var theme: MarkdownTheme
            var livePreview = true
            var focusMode = false
            var imageBase: URL?
            var tagCandidates: [String] = []
            var linkCandidates: [String] = []
            var codeRegions: [CodeCardRegions.Region] = []
            var tableRegions: [TableGrid.Region] = []
            var revealRanges: [NSRange] = []
            var frontmatterLength = 0
            var lastCommandID: UUID?
            var lastFindSignal = 0
            var lastTextLength = 0
            private var lastCursorLine: NSRange?
            private var pendingRestyle: Task<Void, Never>?

            /// Above this size, keystroke restyles are debounced so typing
            /// never waits on a full re-parse.
            private static let debounceThresholdUTF16 = 20000

            init(text: Binding<String>, theme: MarkdownTheme) {
                self.text = text
                self.theme = theme
            }

            func restyle(_ textView: UITextView) {
                let cursor = cursorParagraph(textView)
                lastCursorLine = cursor
                let styled = MarkdownHighlighter.highlight(
                    textView.textStorage,
                    theme: theme,
                    hideMarkersOutside: livePreview ? cursor : nil,
                    dimOutside: focusMode ? cursor : nil
                )
                codeRegions = CodeCardRegions.regions(in: textView.text ?? "", styled: styled)
                tableRegions = TableGrid.regions(in: textView.text ?? "", styled: styled)
                revealRanges = markdownRevealRanges(in: textView.text ?? "", styled: styled)
                frontmatterLength = MarkdownDocument(source: textView.text ?? "").bodyUTF16Offset
            }

            private func scheduleRestyle(_ textView: UITextView) {
                pendingRestyle?.cancel()
                guard ((textView.text ?? "") as NSString).length > Self.debounceThresholdUTF16 else {
                    restyle(textView)
                    return
                }
                pendingRestyle = Task { [weak self, weak textView] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self, let textView else { return }
                    restyle(textView)
                }
            }

            private func cursorParagraph(_ textView: UITextView) -> NSRange {
                let ns = (textView.text ?? "") as NSString
                let location = min(textView.selectedRange.location, ns.length)
                return ns.paragraphRange(for: NSRange(location: location, length: 0))
            }

            public func textViewDidChange(_ textView: UITextView) {
                text.wrappedValue = textView.text
                scheduleRestyle(textView)
            }

            public func textView(
                _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String
            ) -> Bool {
                let full = textView.text ?? ""
                let edit: EditResult? = switch replacement {
                case "\n" where range.length == 0:
                    MarkdownEditing.newlineContinuation(in: full, selection: range)
                case "\t":
                    MarkdownEditing.indentListItems(in: full, selection: range, outdent: false)
                default:
                    nil
                }
                guard let edit else { return true }
                textView.textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
                textView.selectedRange = edit.selection
                restyle(textView)
                Task { @MainActor in text.wrappedValue = textView.text }
                return false
            }

            public func textContentStorage(
                _ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange
            ) -> NSTextParagraph? {
                guard livePreview,
                      !codeRegions.contains(where: { NSIntersectionRange($0.range, range).length > 0 }),
                      let storage = textContentStorage.textStorage,
                      NSMaxRange(range) <= storage.length,
                      let swapped = ListGlyphSubstitution.substituted(
                          paragraph: storage.attributedSubstring(from: range)
                      )
                else { return nil }
                return NSTextParagraph(attributedString: swapped)
            }

            public func textLayoutManager(
                _ textLayoutManager: NSTextLayoutManager,
                textLayoutFragmentFor _: NSTextLocation,
                in textElement: NSTextElement
            ) -> NSTextLayoutFragment {
                if let contentManager = textLayoutManager.textContentManager,
                   let elementRange = textElement.elementRange {
                    let start = contentManager.offset(
                        from: contentManager.documentRange.location, to: elementRange.location
                    )
                    let end = contentManager.offset(
                        from: contentManager.documentRange.location, to: elementRange.endLocation
                    )
                    let paragraphRange = NSRange(location: start, length: max(end - start, 0))
                    // Frontmatter lines never get decorated fragments (its
                    // "---" fences are not thematic breaks).
                    if start < frontmatterLength {
                        return NSTextLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                    }
                    if let table = tableRegions.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }), let cursorLine = lastCursorLine,
                    NSIntersectionRange(table.range, cursorLine).length == 0,
                    let row = table.rows.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = TableRowLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.cells = row.cells
                        fragment.columns = TableGrid.columnLayout(
                            for: table, headerFont: theme.tableHeaderFont, bodyFont: theme.baseFont
                        )
                        fragment.isSeparator = row.isSeparator
                        fragment.isHeader = row.range == table.rows.first?.range
                        fragment.isFirstRow = fragment.isHeader
                        fragment.isLastRow = row.range == table.rows.last?.range
                        fragment.theme = theme
                        return fragment
                    }
                    if let region = codeRegions.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = CodeCardLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.roundsTop = paragraphRange.location <= region.range.location
                        fragment.roundsBottom = NSMaxRange(paragraphRange) >= NSMaxRange(region.range)
                        fragment.badge = fragment.roundsTop ? region.language : nil
                        fragment.fillColor = theme.surfaceBackground
                        fragment.badgeColor = theme.secondaryColor
                        return fragment
                    }
                }
                if let paragraph = textElement as? NSTextParagraph {
                    let content = paragraph.attributedString.string
                    if BlockquoteDetection.isQuoteParagraph(content) {
                        let fragment = QuoteBarLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.barColor = theme.quoteAccent
                        return fragment
                    }
                    if ThematicBreakDetection.isRuleParagraph(content) {
                        let fragment = RuleLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.lineColor = theme.focusDimColor
                        return fragment
                    }
                    if let source = ImageThumbnails.standaloneImageSource(content) {
                        let fragment = ImageLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.source = source
                        fragment.baseURL = imageBase
                        return fragment
                    }
                }
                return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            }

            public func textViewDidChangeSelection(_ textView: UITextView) {
                guard livePreview || focusMode else { return }
                let cursor = cursorParagraph(textView)
                guard cursor != lastCursorLine else { return }
                if focusMode || cursorTransitionAffectsLayout(from: lastCursorLine, to: cursor) {
                    restyle(textView)
                } else {
                    lastCursorLine = cursor
                }
            }

            private func cursorTransitionAffectsLayout(from old: NSRange?, to new: NSRange) -> Bool {
                revealRanges.contains { range in
                    NSIntersectionRange(range, new).length > 0
                        || old.map { NSIntersectionRange(range, $0).length > 0 } ?? false
                }
            }

            // MARK: Checkbox taps

            private func checkboxToken(at point: CGPoint, in textView: UITextView) -> TaskCheckboxToken? {
                guard let position = textView.closestPosition(to: point) else { return nil }
                let index = textView.offset(from: textView.beginningOfDocument, to: position)
                let text = textView.text ?? ""
                let tokens = TaskCheckboxes.tokens(in: text, styled: MarkdownStyler.styleRanges(in: text))
                // A tap "on" the token includes its trailing edge.
                return tokens.first {
                    NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index
                }
            }

            public func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldReceive touch: UITouch
            ) -> Bool {
                guard let textView = gestureRecognizer.view as? UITextView else { return false }
                return checkboxToken(at: touch.location(in: textView), in: textView) != nil
            }

            @objc func handleCheckboxTap(_ gesture: UITapGestureRecognizer) {
                guard let textView = gesture.view as? UITextView,
                      let token = checkboxToken(at: gesture.location(in: textView), in: textView),
                      let updated = RecurrenceEngine.completeTask(in: textView.text ?? "", tokenRange: token.range)
                else { return }
                textView.text = updated
                text.wrappedValue = updated
                restyle(textView)
            }
        }
    }
#endif

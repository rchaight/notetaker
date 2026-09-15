import MarkdownKit
import SwiftUI
import TaskEngine

// TextKit 2 markdown editor with live syntax styling on every keystroke.
// The underlying storage is always the plain CommonMark source — styling is
// attributes only, so the file on disk stays valid markdown.
//
// Everything whose appearance depends on the caret (syntax markers, table
// and thematic-break bodies, frontmatter) is owned by `RevealScope` and
// `MarkdownHighlighter.updateReveal`: a caret move re-applies attributes
// only where the reveal actually flipped, and never re-parses.

/// One full parse of the note plus what the caret path derives from it.
/// Cleared the moment the text changes (and length-checked on use), so the
/// caret path either trusts it or leaves the work to the restyle that the
/// text change already scheduled.
struct EditorParseCache {
    let length: Int
    let styled: [StyledRange]
    let groups: [SyntaxMarkers.MarkerGroup]
    let folds: [NSRange]
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
        var mentionCandidates: [String]
        var findSignal: Int
        var importAttachments: (([AttachmentDrop]) async -> [String])?
        /// Fires on caret/selection change with the format bar's active
        /// state — never re-parses; reuses the coordinator's style ranges.
        var onSelectionContext: ((SelectionContext) -> Void)?
        /// Fires with an image fragment's raw markdown source when the user
        /// clicks a rendered thumbnail.
        var onOpenAttachment: ((String) -> Void)?

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
            mentionCandidates: [String] = [],
            findSignal: Int = 0,
            importAttachments: (([AttachmentDrop]) async -> [String])? = nil,
            onSelectionContext: ((SelectionContext) -> Void)? = nil,
            onOpenAttachment: ((String) -> Void)? = nil
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
            self.mentionCandidates = mentionCandidates
            self.findSignal = findSignal
            self.importAttachments = importAttachments
            self.onSelectionContext = onSelectionContext
            self.onOpenAttachment = onOpenAttachment
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
               let textView = cached.documentView as? MarkdownTextView,
               context.coordinator === SharedEditorCache.coordinator {
                context.coordinator.livePreview = livePreview
                context.coordinator.focusMode = focusMode
                context.coordinator.imageBase = imageBase
                context.coordinator.tagCandidates = tagCandidates
                context.coordinator.linkCandidates = linkCandidates
                context.coordinator.mentionCandidates = mentionCandidates
                textView.importAttachments = importAttachments
                if textView.string != text {
                    textView.string = text
                    context.coordinator.restyle(textView)
                }
                return cached
            }
            // Construct the subclass on its own fresh TextKit 2 stack. The
            // earlier factory-then-swap approach reattached the stock
            // view's text container to a new view, but the layout manager
            // kept rendering into the detached original — notes opened
            // blank (user-reported).
            let textView = MarkdownTextView.makeTextKit2()
            textView.minSize = .zero
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isVerticallyResizable = true
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.documentView = textView
            textView.importAttachments = importAttachments
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
            // Margin clicks fold/unfold headings. A click gesture cannot
            // work here: NSTextView's mouseDown runs a modal tracking loop
            // that swallows the mouseUp, so recognition never completes. A
            // local monitor sees the mouseDown before dispatch and consumes
            // it for margin clicks on heading lines only.
            context.coordinator.installFoldClickMonitor(for: textView)
            // Expanded chevrons draw hover-only — track the pointer so the
            // hovered heading line can reveal its ▾.
            textView.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: context.coordinator,
                userInfo: nil
            ))
            context.coordinator.hoverTextView = textView
            context.coordinator.livePreview = livePreview
            context.coordinator.focusMode = focusMode
            context.coordinator.imageBase = imageBase
            context.coordinator.tagCandidates = tagCandidates
            context.coordinator.linkCandidates = linkCandidates
            context.coordinator.mentionCandidates = mentionCandidates
            context.coordinator.restyle(textView)
            if SharedEditorCache.scrollView == nil {
                SharedEditorCache.scrollView = scrollView
            }
            return scrollView
        }

        public func updateNSView(_ scrollView: NSScrollView, context: Context) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            (textView as? MarkdownTextView)?.importAttachments = importAttachments
            let modeChanged = context.coordinator.livePreview != livePreview
                || context.coordinator.focusMode != focusMode
                || context.coordinator.theme.baseFontSize != theme.baseFontSize
                || context.coordinator.theme.fontDesign != theme.fontDesign
                || context.coordinator.theme.findHighlightName != theme.findHighlightName
            context.coordinator.theme = theme
            context.coordinator.livePreview = livePreview
            context.coordinator.focusMode = focusMode
            context.coordinator.imageBase = imageBase
            context.coordinator.tagCandidates = tagCandidates
            context.coordinator.linkCandidates = linkCandidates
            context.coordinator.mentionCandidates = mentionCandidates
            context.coordinator.onSelectionContext = onSelectionContext
            context.coordinator.onOpenAttachment = onOpenAttachment
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
            // ⌘F: pop the native find bar (one-shot by signal) and start
            // our own bold match highlighting — NSTextFinder's colors are
            // not customizable, so we tint every match ourselves from the
            // system find pasteboard while the bar is open.
            if findSignal != context.coordinator.lastFindSignal {
                context.coordinator.lastFindSignal = findSignal
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.window?.makeFirstResponder(textView)
                textView.performTextFinderAction(item)
                context.coordinator.startFindWatcher(textView)
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
            var mentionCandidates: [String] = []
            var codeRegions: [CodeCardRegions.Region] = []
            var tableRegions: [TableGrid.Region] = []
            var tagChipRanges: [(range: NSRange, color: PlatformColor)] = []
            var foldedKeys: Set<String> = []
            var headingInfos: [HeadingFolding.HeadingInfo] = []
            var hoveredHeadingKey: String?
            weak var hoverTextView: NSTextView?
            var frontmatterLength = 0
            var lastCommandID: UUID?
            var lastFindSignal = 0
            var lastTextLength = 0
            var findWatcher: Task<Void, Never>?
            var lastFindTerm = ""
            var onSelectionContext: ((SelectionContext) -> Void)?
            var onOpenAttachment: ((String) -> Void)?
            /// Style ranges from the last restyle pass — SelectionContext
            /// reuses these on every caret move instead of re-parsing.
            private var currentStyledRanges: [StyledRange] = []
            /// The last full parse; caret moves reuse it instead of parsing.
            private var parseCache: EditorParseCache?
            /// The reveal the storage's attributes currently reflect.
            private var revealScope: RevealScope?
            private var lastPublishedContext: SelectionContext?
            private var imageClickMonitor: Any?
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
                installImageClickMonitorIfNeeded(for: textView)
                let source = textView.string
                let cursor = cursorParagraph(textView)
                lastCursorLine = cursor
                let scope = livePreview ? RevealScope.at(textView.selectedRange(), in: source) : nil
                let prepass = MarkdownStyler.styleRanges(in: source)
                let groups = SyntaxMarkers.markerGroups(in: source, styled: prepass)
                headingInfos = HeadingFolding.headings(in: source, styled: prepass)
                let folds = HeadingFolding.foldRanges(
                    foldedKeys: foldedKeys, in: source, styled: prepass
                )
                let styled = MarkdownHighlighter.highlight(
                    storage,
                    theme: theme,
                    styled: prepass,
                    groups: groups,
                    reveal: scope,
                    dimOutside: focusMode ? cursor : nil,
                    foldRanges: folds
                )
                codeRegions = CodeCardRegions.regions(in: textView.string, styled: styled)
                tableRegions = TableGrid.regions(in: textView.string, styled: styled)
                parseCache = EditorParseCache(
                    length: (source as NSString).length, styled: styled, groups: groups, folds: folds
                )
                revealScope = scope
                tagChipRanges = styled.compactMap { item in
                    switch item.kind {
                    case let .tag(name):
                        (item.range, MarkdownTheme.tagColor(name))
                    case .mention:
                        (item.range, PlatformColor.systemIndigo)
                    case let .kindToken(kind):
                        (item.range, MarkdownTheme.kindColor(kind))
                    default:
                        nil
                    }
                }
                frontmatterLength = MarkdownDocument(source: textView.string).bodyUTF16Offset
                currentStyledRanges = styled
                publishSelectionContext(for: textView)
            }

            private func scheduleRestyle(_ textView: NSTextView) {
                pendingRestyle?.cancel()
                // The text moved: the cached parse no longer describes it,
                // so the caret path must not build on it.
                parseCache = nil
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

            /// Polls the find pasteboard while the find bar is visible and
            /// paints all matches in the theme's find color; closing the
            /// bar restyles clean and stops the watcher.
            func startFindWatcher(_ textView: NSTextView) {
                findWatcher?.cancel()
                lastFindTerm = ""
                findWatcher = Task { [weak self, weak textView] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard let self, let textView else { return }
                        let visible = textView.enclosingScrollView?.isFindBarVisible ?? false
                        let term = visible
                            ? (NSPasteboard(name: .findPboard).string(forType: .string) ?? "")
                            : ""
                        if term != lastFindTerm {
                            lastFindTerm = term
                            restyle(textView)
                            if !term.isEmpty {
                                highlightFindMatches(term, in: textView)
                            }
                        }
                        if !visible, lastFindTerm.isEmpty {
                            return
                        }
                    }
                }
            }

            private func highlightFindMatches(_ term: String, in textView: NSTextView) {
                guard let storage = textView.textStorage else { return }
                let ns = textView.string as NSString
                var searchRange = NSRange(location: 0, length: ns.length)
                storage.beginEditing()
                while true {
                    let found = ns.range(
                        of: term, options: [.caseInsensitive], range: searchRange
                    )
                    guard found.location != NSNotFound else { break }
                    storage.addAttribute(
                        .backgroundColor, value: theme.findHighlightColor, range: found
                    )
                    let next = NSMaxRange(found)
                    guard next < ns.length else { break }
                    searchRange = NSRange(location: next, length: ns.length - next)
                }
                storage.endEditing()
            }

            private var foldClickMonitor: Any?

            func installFoldClickMonitor(for textView: NSTextView) {
                if let existing = foldClickMonitor {
                    NSEvent.removeMonitor(existing)
                }
                foldClickMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: .leftMouseDown
                ) { [weak self, weak textView] event in
                    guard let self, let textView, event.window === textView.window
                    else { return event }
                    let point = textView.convert(event.locationInWindow, from: nil)
                    // Only the left margin folds — normal clicks edit.
                    guard textView.bounds.contains(point),
                          point.x < textView.textContainerInset.width,
                          let heading = heading(at: point, in: textView)
                    else { return event }
                    if foldedKeys.contains(heading.key) {
                        foldedKeys.remove(heading.key)
                    } else {
                        foldedKeys.insert(heading.key)
                    }
                    restyle(textView)
                    return nil
                }
            }

            private func heading(
                at point: NSPoint, in textView: NSTextView
            ) -> HeadingFolding.HeadingInfo? {
                // The view point includes textContainerInset; fragment
                // hit-testing wants layout coordinates, which start below
                // the inset — unconverted, every hit lands one line off.
                let inset = textView.textContainerInset
                let layoutPoint = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
                guard let layoutManager = textView.textLayoutManager,
                      let contentManager = layoutManager.textContentManager,
                      let fragment = layoutManager.textLayoutFragment(for: layoutPoint),
                      let elementRange = fragment.textElement?.elementRange
                else { return nil }
                let start = contentManager.offset(
                    from: contentManager.documentRange.location, to: elementRange.location
                )
                return headingInfos.first(where: {
                    ($0.range.location ..< NSMaxRange($0.range)).contains(start)
                        || (textView.string as NSString)
                        .paragraphRange(for: $0.range).location == start
                })
            }

            /// Explicit selectors: AppKit messages the tracking-area owner
            /// with `mouseMoved:`/`mouseExited:`; Swift would otherwise
            /// export these as `mouseMovedWith:` and they'd never fire.
            @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
                guard let textView = hoverTextView, event.window === textView.window
                else { return }
                let point = textView.convert(event.locationInWindow, from: nil)
                setHoveredHeading(heading(at: point, in: textView)?.key, in: textView)
            }

            @objc(mouseExited:) func mouseExited(with _: NSEvent) {
                guard let textView = hoverTextView else { return }
                setHoveredHeading(nil, in: textView)
            }

            private func setHoveredHeading(_ key: String?, in textView: NSTextView) {
                guard key != hoveredHeadingKey else { return }
                let previous = hoveredHeadingKey
                hoveredHeadingKey = key
                for changed in Set([previous, key].compactMap(\.self)) {
                    invalidateHeadingParagraph(changed, in: textView)
                }
            }

            /// Re-lays-out one heading paragraph so its fold fragment is
            /// rebuilt with the current hover state. Direct
            /// invalidateLayout never repaints TextKit 2 fragment surfaces;
            /// an attributes-changed edit routes through the same pipeline
            /// keystrokes use, which reliably recreates the fragment.
            private func invalidateHeadingParagraph(_ key: String, in textView: NSTextView) {
                guard let heading = headingInfos.first(where: { $0.key == key }),
                      let storage = textView.textStorage else { return }
                let paragraph = (textView.string as NSString).paragraphRange(for: heading.range)
                guard NSMaxRange(paragraph) <= storage.length else { return }
                storage.beginEditing()
                storage.edited(.editedAttributes, range: paragraph, changeInLength: 0)
                storage.endEditing()
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

            private func candidatePool(_ kind: AutocompleteContext.Kind) -> [String] {
                switch kind {
                case .tag: tagCandidates
                case .wikilink: linkCandidates
                case .mention: mentionCandidates
                case .kindToken: AutocompleteContext.kindVocabulary
                }
            }

            private func hasCandidates(for match: AutocompleteContext.Match) -> Bool {
                !AutocompleteContext.completionStrings(
                    query: match.query, partialLength: 0,
                    candidates: candidatePool(match.kind)
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
                case .mention:
                    AutocompleteContext.completionStrings(
                        query: match.query, partialLength: charRange.length,
                        candidates: mentionCandidates
                    )
                case .kindToken:
                    AutocompleteContext.completionStrings(
                        query: match.query, partialLength: charRange.length,
                        candidates: AutocompleteContext.kindVocabulary
                    )
                }
            }

            public func textViewDidChangeSelection(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                updateTableTracking(textView)
                // Format-bar state tracks the caret independent of live
                // preview / focus mode — publish first, then fall through to
                // the (mode-gated) layout-restyle decision below.
                publishSelectionContext(for: textView)
                guard livePreview || focusMode else { return }
                let cursor = cursorParagraph(textView)
                // Focus mode's dim region moves with the caret's paragraph,
                // so it stays a whole-document pass — but only when the
                // paragraph actually changed.
                if focusMode {
                    guard cursor != lastCursorLine else { return }
                    restyle(textView)
                    return
                }
                applyRevealUpdate(textView, cursor: cursor)
            }

            /// Live Preview caret move: the parse cannot have changed, so
            /// reuse the cached one and re-apply attributes only where the
            /// reveal flipped (the caret's line for block syntax, the
            /// touched span for inline). No parse, no whole-note restyle.
            private func applyRevealUpdate(_ textView: NSTextView, cursor: NSRange) {
                guard let storage = textView.textStorage,
                      let cache = parseCache, cache.length == storage.length
                else {
                    // No parse to trust: the text just changed, and its own
                    // restyle (already scheduled, possibly debounced) owns
                    // the reveal. Parsing here too would double the work of
                    // every keystroke.
                    return
                }
                lastCursorLine = cursor
                let scope = RevealScope.at(textView.selectedRange(), in: textView.string)
                guard scope != revealScope else { return }
                MarkdownHighlighter.updateReveal(
                    storage,
                    theme: theme,
                    styled: cache.styled,
                    groups: cache.groups,
                    from: revealScope,
                    to: scope,
                    foldRanges: cache.folds
                )
                revealScope = scope
            }

            // MARK: Table auto-align

            /// The table the cursor is inside: where it starts, plus its
            /// text as of the moment we entered. Leaving a table whose text
            /// changed while we were in it re-aligns the pipes; nothing is
            /// ever rewritten while the cursor is still in the table,
            /// because that would shove the caret around mid-edit.
            private var tableAnchor: Int?
            private var tableSnapshot: String?

            private func updateTableTracking(_ textView: NSTextView) {
                let ns = textView.string as NSString
                let location = textView.selectedRange().location
                // tableRegions refreshes in restyle, which runs AFTER this
                // notification (and debounced on large notes) — after a
                // deletion a stale region can reach past the current text.
                let region = tableRegions.first {
                    NSMaxRange($0.range) <= ns.length
                        && location >= $0.range.location && location <= NSMaxRange($0.range)
                }
                guard region?.range.location != tableAnchor else { return }
                let leaving = tableAnchor
                let snapshot = tableSnapshot
                tableAnchor = region?.range.location
                tableSnapshot = region.map { ns.substring(with: $0.range) }
                guard let leaving, let snapshot else { return }
                alignTable(anchoredAt: leaving, changedFrom: snapshot, in: textView)
            }

            /// One step out of the selection notification: mutating text
            /// from inside a delegate callback re-enters that same
            /// callback, and the hop lets the click that moved the cursor
            /// settle first.
            private func alignTable(
                anchoredAt anchor: Int, changedFrom snapshot: String, in textView: NSTextView
            ) {
                Task { @MainActor [weak textView] in
                    guard let textView else { return }
                    let ns = textView.string as NSString
                    let cursor = textView.selectedRange().location
                    guard let region = TableEditing.regions(in: textView.string)
                        .first(where: { $0.range.location == anchor }),
                        NSMaxRange(region.range) <= ns.length,
                        ns.substring(with: region.range) != snapshot,
                        cursor < region.range.location || cursor > NSMaxRange(region.range),
                        let edit = TableEditing.align(
                            in: textView.string, region: region, selection: textView.selectedRange()
                        )
                    else { return }
                    // One undo group: the align is a single ⌘Z away and
                    // never coalesces with whatever gets typed next.
                    textView.undoManager?.beginUndoGrouping()
                    textView.insertText(edit.replacement, replacementRange: edit.range)
                    textView.setSelectedRange(edit.selection)
                    textView.undoManager?.endUndoGrouping()
                }
            }

            /// Computed from the ranges the last restyle already produced —
            /// never a fresh parse — and skipped when unchanged so the
            /// format bar doesn't republish on every no-op caret tick.
            private func publishSelectionContext(for textView: NSTextView) {
                guard let onSelectionContext else { return }
                let context = SelectionContext.at(textView.selectedRange(), ranges: currentStyledRanges)
                guard context != lastPublishedContext else { return }
                lastPublishedContext = context
                onSelectionContext(context)
            }

            /// Images aren't NSLinks, so clicks on their rendered thumbnail
            /// need their own hit test — mirrors the fold-click monitor's
            /// approach (NSTextView's mouseDown runs a modal tracking loop
            /// that swallows a click gesture's mouseUp).
            private func installImageClickMonitorIfNeeded(for textView: NSTextView) {
                guard imageClickMonitor == nil else { return }
                imageClickMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: .leftMouseDown
                ) { [weak self, weak textView] event in
                    guard let self, let textView, event.window === textView.window,
                          let onOpenAttachment,
                          let source = imageSource(at: event, in: textView)
                    else { return event }
                    onOpenAttachment(source)
                    return nil
                }
            }

            private func imageSource(at event: NSEvent, in textView: NSTextView) -> String? {
                let point = textView.convert(event.locationInWindow, from: nil)
                guard textView.bounds.contains(point) else { return nil }
                let inset = textView.textContainerInset
                let layoutPoint = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
                guard let layoutManager = textView.textLayoutManager,
                      let fragment = layoutManager.textLayoutFragment(for: layoutPoint) as? ImageLayoutFragment,
                      let source = fragment.source
                else { return nil }
                let origin = fragment.layoutFragmentFrame.origin
                let localPoint = NSPoint(x: layoutPoint.x - origin.x, y: layoutPoint.y - origin.y)
                return fragment.hitTestsImage(at: localPoint) ? source : nil
            }

            public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                let selection = textView.selectedRange()
                func apply(_ edit: EditResult) -> Bool {
                    textView.insertText(edit.replacement, replacementRange: edit.range)
                    textView.setSelectedRange(edit.selection)
                    return true
                }
                /// Tab/Shift-Tab inside a table: select the target cell, or
                /// apply the edit that had to grow the table first.
                func tableMove(_ move: TableEditing.CellMove?) -> Bool {
                    switch move {
                    case let .select(range):
                        textView.setSelectedRange(range)
                        return true
                    case let .edit(edit):
                        return apply(edit)
                    case nil:
                        return false
                    }
                }
                // Tab/Return in a table move between cells instead of
                // indenting or breaking the line — but only a pipe on the
                // cursor's line unlocks the parse, so list and prose typing
                // costs nothing.
                let inTable = TableEditing.lineCouldBeTableRow(
                    in: textView.string, location: selection.location
                )
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)):
                    if inTable, let edit = TableEditing.edit(
                        for: .tableInsertRow, in: textView.string, selection: selection
                    ) {
                        return apply(edit)
                    }
                    if let edit = MarkdownEditing.newlineContinuation(in: textView.string, selection: selection) {
                        return apply(edit)
                    }
                case #selector(NSResponder.insertTab(_:)):
                    if inTable, tableMove(
                        TableEditing.nextCell(in: textView.string, selection: selection)
                    ) {
                        return true
                    }
                    if let edit = MarkdownEditing.indentListItems(
                        in: textView.string,
                        selection: selection,
                        outdent: false
                    ) {
                        return apply(edit)
                    }
                case #selector(NSResponder.insertBacktab(_:)):
                    if inTable, tableMove(
                        TableEditing.previousCell(in: textView.string, selection: selection)
                    ) {
                        return true
                    }
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
                    // Frontmatter renders as one rounded properties card
                    // sliced across its paragraphs: never a divider (its
                    // "---" fences are not thematic breaks) and never
                    // collapsed, so entering the block moves nothing.
                    if start < frontmatterLength {
                        guard livePreview else {
                            return NSTextLayoutFragment(
                                textElement: textElement, range: textElement.elementRange
                            )
                        }
                        let fragment = FrontmatterLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.roundsTop = start == 0
                        fragment.roundsBottom = end >= frontmatterLength
                        fragment.fillColor = theme.frontmatterCardBackground
                        return fragment
                    }
                    // The grid draws in BOTH caret states (the pipes stay
                    // visible as the column separators), so there is no
                    // flip between a drawn grid and raw pipes on entry.
                    if livePreview, let table = tableRegions.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }), let row = table.rows.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = TableRowLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
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
                    if let heading = headingInfos.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = HeadingFoldFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.folded = foldedKeys.contains(heading.key)
                        fragment.hovered = heading.key == hoveredHeadingKey
                        return fragment
                    }
                    let chipHits = tagChipRanges.filter {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }
                    if !chipHits.isEmpty {
                        let fragment = TagChipLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.chips = chipHits.map { hit in
                            (
                                NSRange(
                                    location: hit.range.location - paragraphRange.location,
                                    length: hit.range.length
                                ),
                                hit.color
                            )
                        }
                        let chipFont = theme.tagChipFont
                        fragment.glyphAscent = chipFont.ascender
                        fragment.glyphDescent = chipFont.descender
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
        var mentionCandidates: [String]
        var findSignal: Int
        var importAttachments: (([AttachmentDrop]) async -> [String])?
        /// Mirrors the macOS callback (cheap: reuses ranges from the last
        /// restyle). Bar UI is macOS-first but nothing here is iOS-unsafe.
        var onSelectionContext: ((SelectionContext) -> Void)?
        /// Unused on iOS this pass — kept for API parity with macOS so
        /// callers don't need platform-conditional construction.
        var onOpenAttachment: ((String) -> Void)?

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
            mentionCandidates: [String] = [],
            findSignal: Int = 0,
            importAttachments: (([AttachmentDrop]) async -> [String])? = nil,
            onSelectionContext: ((SelectionContext) -> Void)? = nil,
            onOpenAttachment: ((String) -> Void)? = nil
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
            self.mentionCandidates = mentionCandidates
            self.findSignal = findSignal
            self.importAttachments = importAttachments
            self.onSelectionContext = onSelectionContext
            self.onOpenAttachment = onOpenAttachment
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, theme: theme)
        }

        public func makeUIView(context: Context) -> UITextView {
            // usingTextLayoutManager: TextKit 2 storage/layout.
            let textView = MarkdownUITextView(usingTextLayoutManager: true)
            textView.importAttachments = importAttachments
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
            context.coordinator.mentionCandidates = mentionCandidates
            context.coordinator.restyle(textView)
            return textView
        }

        public func updateUIView(_ textView: UITextView, context: Context) {
            (textView as? MarkdownUITextView)?.importAttachments = importAttachments
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
            context.coordinator.mentionCandidates = mentionCandidates
            context.coordinator.onSelectionContext = onSelectionContext
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
            var mentionCandidates: [String] = []
            var codeRegions: [CodeCardRegions.Region] = []
            var tableRegions: [TableGrid.Region] = []
            var tagChipRanges: [(range: NSRange, color: PlatformColor)] = []
            var foldedKeys: Set<String> = []
            var headingInfos: [HeadingFolding.HeadingInfo] = []
            var frontmatterLength = 0
            var lastCommandID: UUID?
            var lastFindSignal = 0
            var lastTextLength = 0
            var onSelectionContext: ((SelectionContext) -> Void)?
            private var currentStyledRanges: [StyledRange] = []
            /// The last full parse; caret moves reuse it instead of parsing.
            private var parseCache: EditorParseCache?
            /// The reveal the storage's attributes currently reflect.
            private var revealScope: RevealScope?
            private var lastPublishedContext: SelectionContext?
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
                let source = textView.text ?? ""
                let cursor = cursorParagraph(textView)
                lastCursorLine = cursor
                let scope = livePreview ? RevealScope.at(textView.selectedRange, in: source) : nil
                let prepass = MarkdownStyler.styleRanges(in: source)
                let groups = SyntaxMarkers.markerGroups(in: source, styled: prepass)
                headingInfos = HeadingFolding.headings(in: source, styled: prepass)
                let folds = HeadingFolding.foldRanges(
                    foldedKeys: foldedKeys, in: source, styled: prepass
                )
                let styled = MarkdownHighlighter.highlight(
                    textView.textStorage,
                    theme: theme,
                    styled: prepass,
                    groups: groups,
                    reveal: scope,
                    dimOutside: focusMode ? cursor : nil,
                    foldRanges: folds
                )
                codeRegions = CodeCardRegions.regions(in: textView.text ?? "", styled: styled)
                tableRegions = TableGrid.regions(in: textView.text ?? "", styled: styled)
                parseCache = EditorParseCache(
                    length: (source as NSString).length, styled: styled, groups: groups, folds: folds
                )
                revealScope = scope
                tagChipRanges = styled.compactMap { item in
                    switch item.kind {
                    case let .tag(name):
                        (item.range, MarkdownTheme.tagColor(name))
                    case .mention:
                        (item.range, PlatformColor.systemIndigo)
                    case let .kindToken(kind):
                        (item.range, MarkdownTheme.kindColor(kind))
                    default:
                        nil
                    }
                }
                frontmatterLength = MarkdownDocument(source: textView.text ?? "").bodyUTF16Offset
                currentStyledRanges = styled
                publishSelectionContext(for: textView)
            }

            private func scheduleRestyle(_ textView: UITextView) {
                pendingRestyle?.cancel()
                // The text moved: the cached parse no longer describes it,
                // so the caret path must not build on it.
                parseCache = nil
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
                    // Frontmatter renders as one rounded properties card
                    // sliced across its paragraphs: never a divider (its
                    // "---" fences are not thematic breaks) and never
                    // collapsed, so entering the block moves nothing.
                    if start < frontmatterLength {
                        guard livePreview else {
                            return NSTextLayoutFragment(
                                textElement: textElement, range: textElement.elementRange
                            )
                        }
                        let fragment = FrontmatterLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.roundsTop = start == 0
                        fragment.roundsBottom = end >= frontmatterLength
                        fragment.fillColor = theme.frontmatterCardBackground
                        return fragment
                    }
                    // The grid draws in BOTH caret states (the pipes stay
                    // visible as the column separators), so there is no
                    // flip between a drawn grid and raw pipes on entry.
                    if livePreview, let table = tableRegions.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }), let row = table.rows.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = TableRowLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
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
                    if let heading = headingInfos.first(where: {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }) {
                        let fragment = HeadingFoldFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.folded = foldedKeys.contains(heading.key)
                        // Touch has no hover — chevrons stay visible on iOS.
                        fragment.hovered = true
                        return fragment
                    }
                    let chipHits = tagChipRanges.filter {
                        NSIntersectionRange($0.range, paragraphRange).length > 0
                    }
                    if !chipHits.isEmpty {
                        let fragment = TagChipLayoutFragment(
                            textElement: textElement, range: textElement.elementRange
                        )
                        fragment.chips = chipHits.map { hit in
                            (
                                NSRange(
                                    location: hit.range.location - paragraphRange.location,
                                    length: hit.range.length
                                ),
                                hit.color
                            )
                        }
                        let chipFont = theme.tagChipFont
                        fragment.glyphAscent = chipFont.ascender
                        fragment.glyphDescent = chipFont.descender
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
                publishSelectionContext(for: textView)
                guard livePreview || focusMode else { return }
                let cursor = cursorParagraph(textView)
                // Focus mode's dim region moves with the caret's paragraph,
                // so it stays a whole-document pass.
                if focusMode {
                    guard cursor != lastCursorLine else { return }
                    restyle(textView)
                    return
                }
                applyRevealUpdate(textView, cursor: cursor)
            }

            /// Live Preview caret move: reuse the cached parse and re-apply
            /// attributes only where the reveal flipped — no parse, no
            /// whole-note restyle. Mirrors the macOS coordinator.
            private func applyRevealUpdate(_ textView: UITextView, cursor: NSRange) {
                let storage = textView.textStorage
                guard let cache = parseCache, cache.length == storage.length else {
                    // The text just changed; its own (possibly debounced)
                    // restyle owns the reveal.
                    return
                }
                lastCursorLine = cursor
                let scope = RevealScope.at(textView.selectedRange, in: textView.text ?? "")
                guard scope != revealScope else { return }
                MarkdownHighlighter.updateReveal(
                    storage,
                    theme: theme,
                    styled: cache.styled,
                    groups: cache.groups,
                    from: revealScope,
                    to: scope,
                    foldRanges: cache.folds
                )
                revealScope = scope
            }

            private func publishSelectionContext(for textView: UITextView) {
                guard let onSelectionContext else { return }
                let context = SelectionContext.at(textView.selectedRange, ranges: currentStyledRanges)
                guard context != lastPublishedContext else { return }
                lastPublishedContext = context
                onSelectionContext(context)
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

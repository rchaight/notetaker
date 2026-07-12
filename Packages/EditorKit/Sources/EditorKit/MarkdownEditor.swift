import MarkdownKit
import SwiftUI
import TaskEngine

// TextKit 2 markdown editor with live syntax styling on every keystroke.
// The underlying storage is always the plain CommonMark source — styling
// is attributes only, so the file on disk stays valid markdown.
#if canImport(AppKit)
    import AppKit

    public struct MarkdownEditor: NSViewRepresentable {
        @Binding var text: String
        @Binding var scrollTarget: NSRange?
        var theme: MarkdownTheme
        var livePreview: Bool

        public init(
            text: Binding<String>,
            scrollTarget: Binding<NSRange?> = .constant(nil),
            theme: MarkdownTheme = .default,
            livePreview: Bool = true
        ) {
            _text = text
            _scrollTarget = scrollTarget
            self.theme = theme
            self.livePreview = livePreview
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, theme: theme)
        }

        public func makeNSView(context: Context) -> NSScrollView {
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
            // Hard-wrap to the view: long lines must never widen the
            // window (SwiftUI windows grow to content ideal width).
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
            textView.string = text
            context.coordinator.livePreview = livePreview
            context.coordinator.restyle(textView)
            return scrollView
        }

        public func updateNSView(_ scrollView: NSScrollView, context: Context) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            let modeChanged = context.coordinator.livePreview != livePreview
            context.coordinator.livePreview = livePreview
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
        }

        @MainActor
        public final class Coordinator: NSObject, NSTextViewDelegate {
            let text: Binding<String>
            let theme: MarkdownTheme
            var livePreview = true
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
                let visible = livePreview ? cursorParagraph(textView) : nil
                lastCursorLine = visible
                MarkdownHighlighter.highlight(storage, theme: theme, hideMarkersOutside: livePreview ? visible : nil)
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
            }

            public func textViewDidChangeSelection(_ notification: Notification) {
                guard livePreview, let textView = notification.object as? NSTextView else { return }
                // Only restyle when the cursor moved to a different paragraph.
                if cursorParagraph(textView) != lastCursorLine {
                    restyle(textView)
                }
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
        var theme: MarkdownTheme
        var livePreview: Bool

        public init(
            text: Binding<String>,
            scrollTarget: Binding<NSRange?> = .constant(nil),
            theme: MarkdownTheme = .default,
            livePreview: Bool = true
        ) {
            _text = text
            _scrollTarget = scrollTarget
            self.theme = theme
            self.livePreview = livePreview
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
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
            textView.text = text
            // Editable UITextViews don't tap links, so checkbox toggles get a
            // gesture that only fires when the touch lands on a token.
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleCheckboxTap(_:))
            )
            tap.delegate = context.coordinator
            textView.addGestureRecognizer(tap)
            context.coordinator.livePreview = livePreview
            context.coordinator.restyle(textView)
            return textView
        }

        public func updateUIView(_ textView: UITextView, context: Context) {
            let modeChanged = context.coordinator.livePreview != livePreview
            context.coordinator.livePreview = livePreview
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
        }

        @MainActor
        public final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
            let text: Binding<String>
            let theme: MarkdownTheme
            var livePreview = true
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
                let visible = livePreview ? cursorParagraph(textView) : nil
                lastCursorLine = visible
                MarkdownHighlighter.highlight(
                    textView.textStorage,
                    theme: theme,
                    hideMarkersOutside: livePreview ? visible : nil
                )
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

            public func textViewDidChangeSelection(_ textView: UITextView) {
                guard livePreview else { return }
                if cursorParagraph(textView) != lastCursorLine {
                    restyle(textView)
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

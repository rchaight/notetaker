import MarkdownKit
import SwiftUI

// TextKit 2 markdown editor with live syntax styling on every keystroke.
// The underlying storage is always the plain CommonMark source — styling
// is attributes only, so the file on disk stays valid markdown.
#if canImport(AppKit)
    import AppKit

    public struct MarkdownEditor: NSViewRepresentable {
        @Binding var text: String
        var theme: MarkdownTheme
        var livePreview: Bool

        public init(text: Binding<String>, theme: MarkdownTheme = .default, livePreview: Bool = true) {
            _text = text
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
        }

        public final class Coordinator: NSObject, NSTextViewDelegate {
            let text: Binding<String>
            let theme: MarkdownTheme
            var livePreview = true
            private var lastCursorLine: NSRange?

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

            private func cursorParagraph(_ textView: NSTextView) -> NSRange {
                let ns = textView.string as NSString
                let selection = textView.selectedRange()
                let location = min(selection.location, ns.length)
                return ns.paragraphRange(for: NSRange(location: location, length: 0))
            }

            public func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                text.wrappedValue = textView.string
                restyle(textView)
            }

            public func textViewDidChangeSelection(_ notification: Notification) {
                guard livePreview, let textView = notification.object as? NSTextView else { return }
                // Only restyle when the cursor moved to a different paragraph.
                if cursorParagraph(textView) != lastCursorLine {
                    restyle(textView)
                }
            }
        }
    }

#else
    import UIKit

    public struct MarkdownEditor: UIViewRepresentable {
        @Binding var text: String
        var theme: MarkdownTheme
        var livePreview: Bool

        public init(text: Binding<String>, theme: MarkdownTheme = .default, livePreview: Bool = true) {
            _text = text
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
        }

        public final class Coordinator: NSObject, UITextViewDelegate {
            let text: Binding<String>
            let theme: MarkdownTheme
            var livePreview = true
            private var lastCursorLine: NSRange?

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

            private func cursorParagraph(_ textView: UITextView) -> NSRange {
                let ns = (textView.text ?? "") as NSString
                let location = min(textView.selectedRange.location, ns.length)
                return ns.paragraphRange(for: NSRange(location: location, length: 0))
            }

            public func textViewDidChange(_ textView: UITextView) {
                text.wrappedValue = textView.text
                restyle(textView)
            }

            public func textViewDidChangeSelection(_ textView: UITextView) {
                guard livePreview else { return }
                if cursorParagraph(textView) != lastCursorLine {
                    restyle(textView)
                }
            }
        }
    }
#endif

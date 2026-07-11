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

        public init(text: Binding<String>, theme: MarkdownTheme = .default) {
            _text = text
            self.theme = theme
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
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.string = text
            if let storage = textView.textStorage {
                MarkdownHighlighter.highlight(storage, theme: theme)
            }
            return scrollView
        }

        public func updateNSView(_ scrollView: NSScrollView, context _: Context) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            if textView.string != text {
                textView.string = text
                if let storage = textView.textStorage {
                    MarkdownHighlighter.highlight(storage, theme: theme)
                }
            }
        }

        public final class Coordinator: NSObject, NSTextViewDelegate {
            let text: Binding<String>
            let theme: MarkdownTheme

            init(text: Binding<String>, theme: MarkdownTheme) {
                self.text = text
                self.theme = theme
            }

            public func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                text.wrappedValue = textView.string
                if let storage = textView.textStorage {
                    MarkdownHighlighter.highlight(storage, theme: theme)
                }
            }
        }
    }

#else
    import UIKit

    public struct MarkdownEditor: UIViewRepresentable {
        @Binding var text: String
        var theme: MarkdownTheme

        public init(text: Binding<String>, theme: MarkdownTheme = .default) {
            _text = text
            self.theme = theme
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
            textView.alwaysBounceVertical = true
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
            textView.text = text
            MarkdownHighlighter.highlight(textView.textStorage, theme: theme)
            return textView
        }

        public func updateUIView(_ textView: UITextView, context _: Context) {
            if textView.text != text {
                textView.text = text
                MarkdownHighlighter.highlight(textView.textStorage, theme: theme)
            }
        }

        public final class Coordinator: NSObject, UITextViewDelegate {
            let text: Binding<String>
            let theme: MarkdownTheme

            init(text: Binding<String>, theme: MarkdownTheme) {
                self.text = text
                self.theme = theme
            }

            public func textViewDidChange(_ textView: UITextView) {
                text.wrappedValue = textView.text
                MarkdownHighlighter.highlight(textView.textStorage, theme: theme)
            }
        }
    }
#endif

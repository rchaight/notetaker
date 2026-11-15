#if canImport(AppKit)
    import AppKit
    @testable import EditorKit
    import SwiftUI
    import Testing

    /// An automatic edit or a note switch replaces the whole text from outside the editor. The
    /// undo history of the old text must not survive it: its ranges point into text that is gone.
    @MainActor
    @Suite(.serialized)
    struct ExternalSwapUndoTests {
        private final class Box { var text = "" }

        private nonisolated(unsafe) static var keepAlive: [Any] = []

        private func editor(_ text: String) -> (MarkdownTextView, MarkdownEditor.Coordinator, NSWindow) {
            let box = Box()
            box.text = text
            let binding = Binding(get: { box.text }, set: { box.text = $0 })
            let coordinator = MarkdownEditor.Coordinator(text: binding, theme: .default)
            let textView = MarkdownTextView.makeTextKit2()
            textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            textView.delegate = coordinator
            textView.isRichText = false
            textView.allowsUndo = true
            textView.string = text
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scrollView.documentView = textView
            window.contentView?.addSubview(scrollView)
            window.makeFirstResponder(textView)
            Self.keepAlive.append(contentsOf: [window, scrollView, box] as [Any])
            coordinator.restyle(textView)
            return (textView, coordinator, window)
        }

        /// Types into the view the way the user does, so `NSTextView` registers its own undo.
        private func type(_ string: String, into textView: NSTextView) {
            textView.undoManager?.groupsByEvent = false
            textView.undoManager?.beginUndoGrouping()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.insertText(string, replacementRange: NSRange(location: 0, length: 0))
            textView.undoManager?.endUndoGrouping()
        }

        @Test func typingRegistersUndo() throws {
            let (textView, _, _) = editor("Hello\n")
            type("typed ", into: textView)
            #expect(try #require(textView.undoManager).canUndo)
        }

        /// The premise of the fix, pinned: assigning `string` alone (what the editor did before)
        /// leaves the old history in place.
        @Test func assigningStringAloneLeavesStaleUndoHistory() throws {
            let (textView, _, _) = editor("Hello\n")
            type("typed ", into: textView)
            textView.string = "# 8:30 AM — Meeting\n[[Brief]]\n\nHello\n"
            #expect(try #require(textView.undoManager).canUndo)
        }

        @Test func anExternalSwapDropsTheOldUndoHistory() throws {
            let (textView, coordinator, _) = editor("Hello\n")
            type("typed ", into: textView)
            let undoManager = try #require(textView.undoManager)
            #expect(undoManager.canUndo)

            coordinator.replaceTextFromOutside("# 8:30 AM — Meeting\n[[Brief]]\n\nHello\n", in: textView)
            #expect(textView.string == "# 8:30 AM — Meeting\n[[Brief]]\n\nHello\n")
            #expect(!undoManager.canUndo)
            #expect(!undoManager.canRedo)
            // ⌘Z now does nothing instead of editing the wrong characters.
            undoManager.undo()
            #expect(textView.string == "# 8:30 AM — Meeting\n[[Brief]]\n\nHello\n")
        }

        @Test func typingAfterTheSwapUndoesNormally() throws {
            let (textView, coordinator, _) = editor("Hello\n")
            type("typed ", into: textView)
            coordinator.replaceTextFromOutside("Brief\nHello\n", in: textView)
            type("new ", into: textView)
            let undoManager = try #require(textView.undoManager)
            #expect(undoManager.canUndo)
            undoManager.undo()
            #expect(textView.string == "Brief\nHello\n")
        }
    }
#endif

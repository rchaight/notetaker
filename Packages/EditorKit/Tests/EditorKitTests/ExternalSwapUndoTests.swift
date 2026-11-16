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

        /// The binding behind the editor the last `editor(_:)` call built (the suite is serialized).
        private nonisolated(unsafe) static var lastBox: Box?

        private nonisolated(unsafe) static var keepAlive: [Any] = []

        private func editor(
            _ text: String, coordinator shared: MarkdownEditor.Coordinator? = nil, inWindow: Bool = true
        ) -> (MarkdownTextView, MarkdownEditor.Coordinator, NSWindow) {
            let box = Box()
            box.text = text
            Self.lastBox = box
            let binding = Binding(get: { box.text }, set: { box.text = $0 })
            let coordinator = shared ?? MarkdownEditor.Coordinator(text: binding, theme: .default)
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
            if inWindow {
                window.contentView?.addSubview(scrollView)
                window.makeFirstResponder(textView)
            }
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

        /// ⌘Z goes through the editor's own undo manager, not the window's: the window's is
        /// shared with every other field (search, rename) and doesn't exist off screen.
        @Test func theEditorHasItsOwnUndoManager() throws {
            let (textView, coordinator, window) = editor("Hello\n")
            let own = try #require(textView.undoManager)
            #expect(own === coordinator.undoManager(for: textView))
            #expect(own !== window.undoManager)
            type("typed ", into: textView)
            #expect(own.canUndo)
            #expect(window.undoManager?.canUndo != true)
        }

        /// What the Edit ▸ Undo menu item and ⌘Z do: send `undo:` up the responder chain from
        /// the text view. It must reach the editor's undo manager.
        @Test func undoActionThroughTheResponderChainUsesTheEditorsManager() {
            let (textView, _, _) = editor("Hello\n")
            type("typed ", into: textView)
            #expect(textView.string == "typed Hello\n")
            #expect(textView.tryToPerform(Selector(("undo:")), with: nil))
            #expect(textView.string == "Hello\n")
        }

        /// A cached editor is swapped while it is out of its window (switching back to a tab
        /// that shows another note). The history goes at once, not on some later update, so
        /// the first thing typed afterwards keeps its undo and nothing stale is left to undo.
        @Test func aSwapOffScreenDropsHistoryAtOnceAndKeepsLaterTyping() throws {
            let (textView, coordinator, window) = editor("Hello\n")
            type("typed ", into: textView)
            textView.enclosingScrollView?.removeFromSuperview()
            #expect(textView.window == nil)
            let undoManager = try #require(textView.undoManager)
            #expect(undoManager.canUndo)

            coordinator.replaceTextFromOutside("Other note\n", in: textView)
            #expect(!undoManager.canUndo)

            try window.contentView?.addSubview(#require(textView.enclosingScrollView))
            window.makeFirstResponder(textView)
            type("abc ", into: textView)
            #expect(textView.undoManager === undoManager)
            #expect(undoManager.canUndo)
            undoManager.undo()
            #expect(textView.string == "Other note\n")
            #expect(!undoManager.canUndo)
        }

        /// Two windows share one coordinator (the editor cache); their histories stay apart.
        @Test func twoEditorsSharingACoordinatorKeepSeparateHistories() throws {
            let (first, coordinator, _) = editor("One\n")
            let (second, _, _) = editor("Two\n", coordinator: coordinator)
            type("a ", into: first)
            coordinator.replaceTextFromOutside("Two, swapped\n", in: second)
            #expect(first.undoManager !== second.undoManager)
            #expect(try #require(first.undoManager).canUndo)
        }

        /// A composition in progress (input method) is abandoned by the swap rather than left
        /// pointing into text that is gone, and the binding only ever sees the new text.
        @Test func aSwapAbandonsMarkedText() throws {
            let (textView, coordinator, _) = editor("Hello\n")
            let box = try #require(Self.lastBox)
            textView.setSelectedRange(NSRange(location: 6, length: 0))
            textView.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(textView.hasMarkedText())

            coordinator.replaceTextFromOutside("Brief\nHello\n", in: textView)
            #expect(!textView.hasMarkedText())
            #expect(textView.string == "Brief\nHello\n")
            // The binding (what gets saved) must never see the old text plus the half-composed
            // characters: committing the composition before the swap would push exactly that
            // into the note that is now open (critic, row 245).
            #expect(box.text == "Brief\nHello\n")
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

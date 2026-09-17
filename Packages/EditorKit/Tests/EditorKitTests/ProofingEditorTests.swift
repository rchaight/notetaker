#if canImport(AppKit)
    import AppKit
    @testable import EditorKit
    import MarkdownKit
    import SwiftUI
    import Testing

    /// The live half: a real `NSTextView` on a real TextKit 2 stack with a
    /// real `MarkdownEditor.Coordinator` (pattern: `TableEditorKeyTests`).
    ///
    /// Serialized because these drive the shared system spell checker and
    /// put windows on screen.
    @MainActor
    @Suite(.serialized)
    struct ProofingEditorTests {
        private final class Box { var text = "" }

        /// Windows and scroll views have to outlive the `editor(_:)` call
        /// that made them: an unretained window deallocates and the text
        /// view stops being checked (this cost an hour during step 0).
        private nonisolated(unsafe) static var keepAlive: [Any] = []

        private func editor(_ text: String) -> (MarkdownTextView, MarkdownEditor.Coordinator) {
            let box = Box()
            box.text = text
            let binding = Binding(get: { box.text }, set: { box.text = $0 })
            let coordinator = MarkdownEditor.Coordinator(text: binding, theme: .default)
            let textView = MarkdownTextView.makeTextKit2()
            textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            textView.delegate = coordinator
            textView.isRichText = false
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
            return (textView, coordinator)
        }

        /// The words currently carrying a spelling annotation.
        ///
        /// STEP 0's answer: on a TextKit 2 `NSTextView` the squiggle is a
        /// `.spellingState` RENDERING attribute on the
        /// `NSTextLayoutManager` — not a text-storage attribute and not a
        /// TextKit 1 temporary attribute (both were probed and came back
        /// empty). Do NOT reach for `textView.layoutManager` to look for
        /// it: touching that property drags the view into the TextKit 1
        /// compatibility mode and the question becomes meaningless.
        private func flagged(_ textView: NSTextView) -> [String] {
            guard let manager = textView.textLayoutManager,
                  let content = manager.textContentManager else { return [] }
            let ns = textView.string as NSString
            var words: [String] = []
            manager.enumerateRenderingAttributes(
                from: content.documentRange.location, reverse: false
            ) { _, attributes, range in
                guard attributes[.spellingState] != nil else { return true }
                let start = content.offset(from: content.documentRange.location, to: range.location)
                let end = content.offset(from: content.documentRange.location, to: range.endLocation)
                let span = NSRange(location: start, length: end - start)
                if span.length > 0, NSMaxRange(span) <= ns.length {
                    words.append(ns.substring(with: span))
                }
                return true
            }
            return words
        }

        private func waitForFlags(_ textView: NSTextView) async -> [String] {
            for _ in 0 ..< 80 {
                let words = flagged(textView)
                if !words.isEmpty {
                    return words
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return flagged(textView)
        }

        // MARK: Step 0 — does a full restyle clobber the annotation?

        /// Outcome A, proved deterministically. `setSpellingState` is the
        /// documented way to place the indicator, so this needs no live
        /// spell-checker round trip: place it, run the FULL attribute
        /// re-application (`restyle` → `MarkdownHighlighter.highlight`,
        /// whose first act is `NSTextStorage.setAttributes` over the whole
        /// document), and the annotation must still be there.
        @Test func spellingAnnotationSurvivesAFullRestyle() {
            let source = "The quck brown fox #tagg jumps.\n"
            let (textView, coordinator) = editor(source)
            let word = (source as NSString).range(of: "quck")
            textView.setSpellingState(NSAttributedString.SpellingState.spelling.rawValue, range: word)
            #expect(flagged(textView) == ["quck"])

            coordinator.restyle(textView)
            #expect(flagged(textView) == ["quck"], "restyle clobbered the spelling annotation")

            // …and across the caret path, which re-applies attributes for
            // the paragraphs whose Live Preview reveal flipped.
            textView.setSelectedRange(NSRange(location: word.location, length: 0))
            coordinator.textViewDidChangeSelection(
                Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
            )
            #expect(flagged(textView) == ["quck"], "updateReveal clobbered the spelling annotation")
        }

        /// The same question end to end through the real checker: turn
        /// continuous checking on the way `applyProofing` does, let the
        /// system flag the misspellings, then restyle.
        @Test func systemCheckedAnnotationsSurviveARestyle() async {
            let source = "The quck brown fox jumps over the lazzy dog.\n"
            let (textView, coordinator) = editor(source)
            coordinator.applyProofing(
                ProofingFlags(spelling: true, grammar: true, autocorrect: false),
                to: textView, recheck: true
            )
            let before = await waitForFlags(textView)
            #expect(before.sorted() == ["lazzy", "quck"])

            coordinator.restyle(textView)
            #expect(flagged(textView).sorted() == ["lazzy", "quck"])
        }

        // MARK: The flags

        /// Whether AppKit will honor `isContinuousSpellCheckingEnabled` in
        /// THIS process. It refuses unless `NSAllowContinuousSpellChecking`
        /// read true when the value was first cached, and this machine's
        /// NSGlobalDomain holds 0 — so the opt-in `applyProofing` writes
        /// lands from the next launch, and the flag assertions below can
        /// only be made when the gate is already open. (Asking a throwaway
        /// view is the only honest way to read the cached answer.)
        private var gateIsOpen: Bool {
            let probe = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            probe.isContinuousSpellCheckingEnabled = true
            return probe.isContinuousSpellCheckingEnabled
        }

        @Test func applyProofingMirrorsTheFlagsOntoTheView() {
            let (textView, coordinator) = editor("Some prose.\n")
            coordinator.applyProofing(
                ProofingFlags(spelling: true, grammar: true, autocorrect: false), to: textView
            )
            // The opt-in itself is unconditional and is what makes the
            // feature work from the next launch: if this breaks, the editor
            // goes quiet on any machine whose global default is 0.
            #expect(UserDefaults.standard.bool(forKey: "NSAllowContinuousSpellChecking"))
            #expect(!textView.isAutomaticSpellingCorrectionEnabled)
            if gateIsOpen {
                #expect(textView.isContinuousSpellCheckingEnabled)
                #expect(textView.isGrammarCheckingEnabled)
            }

            coordinator.applyProofing(
                ProofingFlags(spelling: false, grammar: false, autocorrect: true), to: textView
            )
            #expect(!textView.isContinuousSpellCheckingEnabled)
            #expect(!textView.isGrammarCheckingEnabled)
            #expect(textView.isAutomaticSpellingCorrectionEnabled)
        }

        /// Turning spelling off has to take the squiggles with it. AppKit
        /// does that itself when `isContinuousSpellCheckingEnabled` goes
        /// false (probed), so `applyProofing` deliberately doesn't try.
        @Test func turningSpellingOffClearsTheAnnotations() async {
            let source = "The quck brown fox jumps.\n"
            let (textView, coordinator) = editor(source)
            coordinator.applyProofing(
                ProofingFlags(spelling: true, grammar: true, autocorrect: false),
                to: textView, recheck: true
            )
            #expect(await !waitForFlags(textView).isEmpty)
            coordinator.applyProofing(
                ProofingFlags(spelling: false, grammar: true, autocorrect: false), to: textView
            )
            try? await Task.sleep(for: .milliseconds(200))
            #expect(flagged(textView).isEmpty)
        }

        // MARK: The delegate hooks

        /// The silent-failure guard. These three hooks are matched by
        /// selector, and a Swift signature that differs by one nullability
        /// annotation simply never gets called — the editor would look
        /// wired up and check nothing. Assert the bridged selectors exist.
        @Test func coordinatorAnswersTheProofingSelectors() {
            let (_, coordinator) = editor("prose\n")
            for name in [
                "textView:didCheckTextInRange:types:options:results:orthography:wordCount:",
                "textView:willCheckTextInRange:options:types:",
                "textView:writingToolsIgnoredRangesInEnclosingRange:",
            ] {
                #expect(coordinator.responds(to: Selector(name)), "not wired: \(name)")
            }
        }

        /// Acceptance criterion 4. Real results are nondeterministic (the
        /// checker's opinion of `#Amber1` is its own business), so the
        /// results are constructed and fed through the real delegate
        /// method: the prose misspelling survives, everything inside a
        /// token does not.
        @Test func didCheckTextInKeepsProseAndDropsTokens() {
            let source = "- [ ] teh #Amber1 @bob ?discuss >friday\n"
            let (textView, coordinator) = editor(source)
            let ns = source as NSString
            func result(_ needle: String) -> NSTextCheckingResult {
                .spellCheckingResult(range: ns.range(of: needle))
            }
            let teh = result("teh")
            let results = [
                teh, result("Amber1"), result("bob"), result("discuss"), result("friday"),
            ]
            let kept = coordinator.textView(
                textView,
                didCheckTextIn: NSRange(location: 0, length: ns.length),
                types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                options: [:],
                results: results,
                orthography: nil,
                wordCount: 6
            )
            #expect(kept.map(\.range) == [teh.range])
        }

        /// The same filter on the literal prose form from the spec, where
        /// `>friday` is NOT a task token (no checkbox on the line) and so
        /// reads as ordinary text — the chips still go.
        @Test func didCheckTextInFiltersChipsInPlainProse() {
            let source = "teh #Amber1 @bob ?discuss >friday\n"
            let (textView, coordinator) = editor(source)
            let ns = source as NSString
            let kept = coordinator.textView(
                textView,
                didCheckTextIn: NSRange(location: 0, length: ns.length),
                types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                options: [:],
                results: ["teh", "Amber1", "bob", "discuss"].map {
                    .spellCheckingResult(range: ns.range(of: $0))
                },
                orthography: nil,
                wordCount: 5
            )
            #expect(kept.map { ns.substring(with: $0.range) } == ["teh"])
        }

        @Test func willCheckTextInDropsGrammarWhenItIsOff() {
            let (textView, coordinator) = editor("Some prose.\n")
            let spelling = NSTextCheckingResult.CheckingType.spelling.rawValue
            let grammar = NSTextCheckingResult.CheckingType.grammar.rawValue

            func requested(grammarOn: Bool) -> NSTextCheckingTypes {
                coordinator.applyProofing(
                    ProofingFlags(spelling: true, grammar: grammarOn, autocorrect: false),
                    to: textView
                )
                var types: NSTextCheckingTypes = spelling | grammar
                _ = withUnsafeMutablePointer(to: &types) { pointer in
                    coordinator.textView(
                        textView, willCheckTextIn: NSRange(location: 0, length: 11),
                        options: [:], types: pointer
                    )
                }
                return types
            }
            #expect(requested(grammarOn: true) & grammar == grammar)
            #expect(requested(grammarOn: false) & grammar == 0)
            #expect(requested(grammarOn: false) & spelling == spelling)
        }

        @Test func writingToolsIgnoresMarkupRanges() {
            let source = "Keep the prose. Ignore `let x = 1` and #tagg.\n"
            let (textView, coordinator) = editor(source)
            let ns = source as NSString
            let ignored = coordinator.textView(
                textView, writingToolsIgnoredRangesInEnclosingRange:
                NSRange(location: 0, length: ns.length)
            ).map(\.rangeValue)
            #expect(ignored.contains(ns.range(of: "`let x = 1`")))
            #expect(ignored.contains(ns.range(of: "#tagg")))
            #expect(!ignored.contains { NSIntersectionRange($0, ns.range(of: "Keep the prose")).length > 0 })
        }
    }
#endif

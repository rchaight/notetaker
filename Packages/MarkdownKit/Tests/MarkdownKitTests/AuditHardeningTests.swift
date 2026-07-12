import Foundation
@testable import MarkdownKit
import Testing

/// Tests added from the model-tiered coverage audit (pass 46).
struct AuditHardeningTests {
    private func markers(_ text: String) -> [String] {
        let styled = MarkdownStyler.styleRanges(in: text)
        return SyntaxMarkers.markerRanges(in: text, styled: styled)
            .sorted { ($0.location, $0.length) < ($1.location, $1.length) }
            .map { (text as NSString).substring(with: $0) }
    }

    @Test func indentedHeadingMarkersHide() {
        // cmark reports the heading range starting at the hashes; the 1-3
        // leading indent spaces stay visible (harmless), the syntax hides.
        #expect(markers("   ## Indented Heading\n") == ["## "])
    }

    @Test func deepNestedTaskBulletAndTokenAgree() {
        // Five levels of real nesting: the bullet-hiding window and the
        // checkbox-token window must agree at every depth (they briefly
        // used 12 vs 24 chars and diverged — the audit caught it).
        let text = "- [ ] l1\n  - [ ] l2\n    - [ ] l3\n      - [ ] l4\n        - [ ] l5\n"
        let styled = MarkdownStyler.styleRanges(in: text)
        let bullets = SyntaxMarkers.markerRanges(in: text, styled: styled)
            .map { (text as NSString).substring(with: $0) }
            .filter { $0.hasSuffix("- ") }
        let tokens = TaskCheckboxes.tokens(in: text, styled: styled)
        #expect(bullets.count == 5, "every nesting depth hides its bullet")
        #expect(tokens.count == 5, "every nesting depth finds its checkbox token")
    }

    @Test func crlfFrontmatterSplits() {
        let source = "---\r\ntitle: CRLF\r\n---\r\nbody line\r\n"
        let doc = MarkdownDocument(source: source)
        #expect(doc.frontmatter?.values["title"] == "CRLF")
        #expect(doc.render() == source, "round-trip must stay byte-exact")
    }

    @Test func crlfScannerAndTogglerAgree() throws {
        let contents = "# H\r\n- [ ] crlf task\r\nplain\r\n"
        let tasks = NoteScanner.tasks(in: contents)
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        let toggled = TaskLineToggler.toggle(
            contents: contents, anchorLine: task.line, expectedRawLine: task.rawLine
        )
        #expect(toggled != nil, "scanner line anchors must be toggleable on CRLF files")
        #expect(toggled?.contents.contains("[x]") == true)
    }

    @Test func onlyFirstCheckboxOnALineToggles() {
        let line = "- [ ] first [ ] second"
        let result = TaskLineToggler.toggle(contents: line, anchorLine: 0, expectedRawLine: line)
        #expect(result?.contents == "- [x] first [ ] second")
    }

    @Test func toggleImplementationsAgree() throws {
        for line in ["- [ ] open", "- [x] done", "- [X] shouty"] {
            let viaToggler = TaskLineToggler.toggle(contents: line, anchorLine: 0, expectedRawLine: line)?.contents
            let text = line
            let styled = MarkdownStyler.styleRanges(in: text)
            let token = try #require(TaskCheckboxes.tokens(in: text, styled: styled).first)
            let viaCheckboxes = TaskCheckboxes.toggled(text, tokenAt: token.range)
            #expect(viaToggler == viaCheckboxes, "the two toggle paths must be identical for: \(line)")
        }
    }

    @Test func malformedWikilinksDoNotCrashOrEmit() {
        #expect(NoteScanner.wikilinkTargets(in: "[[unterminated and [[]] empty\n") == [])
    }

    @Test func emptyAndNoTrailingNewlineInputs() {
        #expect(NoteScanner.tasks(in: "").isEmpty)
        #expect(NoteScanner.tasks(in: "- [ ] no newline at end").count == 1)
        #expect(MarkdownStyler.styleRanges(in: "").isEmpty)
    }
}

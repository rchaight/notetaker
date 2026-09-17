import Foundation
@testable import TaskEngine
import Testing

/// `tokenRanges` is the geometry half of the ONE parser: EditorKit's
/// proofing exclusions need to know WHERE the tokens are so the system
/// spell checker never squiggles `#Amber1` or `>friday`.
struct TokenRangeTests {
    private func spans(_ line: String) -> [String] {
        let ns = line as NSString
        return TaskTokenParser.tokenRanges(in: line).map { ns.substring(with: $0) }
    }

    @Test func everyTokenKindIsLocated() {
        let line = "- [ ] ship it >friday ~2026-07-01 !p1 #work @bob ?discuss "
            + "&every 2 weeks ^ship blockedby:^spec ✅2026-07-14"
        let found = spans(line)
        for token in [
            ">friday", "~2026-07-01", "!p1", "#work", "@bob", "?discuss",
            "&every 2 weeks", "^ship", "blockedby:^spec", "✅2026-07-14",
        ] {
            #expect(found.contains(token), "missing \(token) in \(found)")
        }
    }

    @Test func rangesAreSortedByLocation() {
        let ranges = TaskTokenParser.tokenRanges(in: "- [ ] a >today !p2 #tag @sam ?next")
        #expect(ranges == ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) })
        #expect(ranges.count == 5)
    }

    @Test func rangesMapBackToTheOriginalLine() {
        // The regression this guards: `parse` finds its tokens by deleting
        // each match from a working copy, so those match ranges drift out
        // of the original line's coordinates. Every range reported here
        // must still name its own token in the UNMODIFIED string.
        let line = "- [ ] ship the thing >friday !p1 #work @bob"
        let ns = line as NSString
        let leaders: Set<Character> = [">", "~", "!", "#", "@", "?", "^", "✅", "&"]
        for range in TaskTokenParser.tokenRanges(in: line) {
            #expect(NSMaxRange(range) <= ns.length)
            let text = ns.substring(with: range)
            #expect(text.first.map { leaders.contains($0) } == true, "stray span \(text)")
        }
    }

    @Test func plainProseYieldsNoTokens() {
        #expect(TaskTokenParser.tokenRanges(in: "- [ ] write the grant narrative").isEmpty)
        #expect(TaskTokenParser.tokenRanges(in: "").isEmpty)
        // Not tokens: no word boundary before them, or off-vocabulary.
        #expect(TaskTokenParser.tokenRanges(in: "- [ ] a>b !p9 ?maybe x@y.com").isEmpty)
    }

    @Test func repeatedTokensAllGetRanges() {
        // `parse` keeps only the first `>date`; the second still LOOKS like
        // a token on screen, so proofing must skip it too.
        #expect(spans("- [ ] a >friday b >monday") == [">friday", ">monday"])
    }

    @Test func impossibleDatesAreStillTokenShaped() {
        // parse() refuses to store 2026-13-45 as metadata…
        #expect(TaskTokenParser.parse("- [ ] a >2026-13-45").dueDate == nil)
        // …but it is still syntax, so it must not be proofread either.
        #expect(spans("- [ ] a >2026-13-45") == [">2026-13-45"])
    }

    @Test func dependencyListsAreOneSpan() {
        #expect(spans("- [ ] a depends:^spec,^api") == ["depends:^spec,^api"])
    }
}

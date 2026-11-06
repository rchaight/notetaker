import Foundation
@testable import MarkdownKit
import Testing

/// The grammar table in specs/ux-phase2/05-wikilink-syntax-and-rename.md —
/// one test per row.
struct WikilinkSyntaxTests {
    private func single(_ text: String) throws -> Wikilink {
        let links = WikilinkSyntax.links(in: text)
        try #require(links.count == 1)
        return links[0]
    }

    // MARK: Grammar

    @Test func parsesPlain() throws {
        let link = try single("[[Plan]]")
        #expect(link.raw == "Plan")
        #expect(link.target == "Plan")
        #expect(link.heading == nil)
        #expect(link.blockId == nil)
        #expect(link.alias == nil)
        #expect(!link.isEmbed)
        #expect(link.range == NSRange(location: 0, length: 8))
        #expect(link.targetRange == NSRange(location: 2, length: 4))
        #expect(link.title == "Plan")
        #expect(link.label == "Plan")
    }

    @Test func parsesAlias() throws {
        let link = try single("[[Plan|the plan]]")
        #expect(link.target == "Plan")
        #expect(link.heading == nil)
        #expect(link.alias == "the plan")
        #expect(link.label == "the plan")
        #expect(link.raw == "Plan|the plan")
    }

    @Test func parsesHeading() throws {
        let link = try single("[[Plan#Budget]]")
        #expect(link.target == "Plan")
        #expect(link.heading == "Budget")
        #expect(link.blockId == nil)
        #expect(link.alias == nil)
        #expect(link.label == "Plan › Budget")
    }

    @Test func parsesHeadingAndAlias() throws {
        let link = try single("[[Plan#Budget|see]]")
        #expect(link.target == "Plan")
        #expect(link.heading == "Budget")
        #expect(link.alias == "see")
        #expect(link.label == "see")
    }

    @Test func parsesBlockId() throws {
        let link = try single("[[Plan#^abc12]]")
        #expect(link.target == "Plan")
        #expect(link.heading == nil)
        #expect(link.blockId == "abc12")
        #expect(link.alias == nil)
        #expect(link.label == "Plan")
    }

    @Test func parsesPath() throws {
        let link = try single("[[Projects/Plan]]")
        #expect(link.target == "Projects/Plan")
        #expect(link.title == "Plan")
        #expect(link.label == "Plan")
        #expect(try single("[[A/B/Plan#H|x]]").title == "Plan")
    }

    @Test func trimsTargetAndReportsTargetRange() throws {
        let text = "see [[ Plan ]] here"
        let link = try single(text)
        #expect(link.target == "Plan")
        #expect(link.raw == " Plan ")
        #expect((text as NSString).substring(with: link.targetRange) == "Plan")
        #expect((text as NSString).substring(with: link.range) == "[[ Plan ]]")
        let spaced = "[[  Plan  #Budget | x ]]"
        let withHeading = try single(spaced)
        #expect(withHeading.target == "Plan")
        #expect(withHeading.heading == "Budget")
        #expect(withHeading.alias == "x")
        #expect((spaced as NSString).substring(with: withHeading.targetRange) == "Plan")
    }

    @Test func selfHeadingLinkHasEmptyTarget() throws {
        let link = try single("[[#Budget]]")
        #expect(link.target == "")
        #expect(link.title == "")
        #expect(link.heading == "Budget")
        #expect(link.label == "Budget")
        #expect(link.targetRange.length == 0)
    }

    @Test func firstPipeSplitsAlias() throws {
        let link = try single("[[a|b|c]]")
        #expect(link.target == "a")
        #expect(link.alias == "b|c")
        // A "#" after the pipe belongs to the alias, not a heading.
        let hashInAlias = try single("[[a|b#c]]")
        #expect(hashInAlias.target == "a")
        #expect(hashInAlias.heading == nil)
        #expect(hashInAlias.alias == "b#c")
    }

    @Test func embedIsLink() throws {
        let text = "x ![[Plan]] y"
        let link = try single(text)
        #expect(link.isEmbed)
        #expect(link.target == "Plan")
        #expect((text as NSString).substring(with: link.range) == "![[Plan]]")
        #expect((text as NSString).substring(with: link.targetRange) == "Plan")
        #expect(try !single("[[Plan]]").isEmbed)
    }

    @Test func malformedAreNotLinks() {
        #expect(WikilinkSyntax.links(in: "[[]]").isEmpty)
        #expect(WikilinkSyntax.links(in: "[[a").isEmpty)
        #expect(WikilinkSyntax.links(in: "[[a\nb]]").isEmpty)
        #expect(WikilinkSyntax.links(in: "[[unterminated and [[]] empty").isEmpty)
        #expect(WikilinkSyntax.links(in: "[[ ]]").isEmpty)
        #expect(WikilinkSyntax.links(in: "[[|alias]]").isEmpty)
        #expect(WikilinkSyntax.links(in: "[single] [[a]").isEmpty)
    }

    @Test func excludedRangesSkipped() {
        let text = "`[[x]]` and [[y]]"
        let code = NSRange(location: 0, length: 7)
        #expect(WikilinkSyntax.links(in: text).map(\.target) == ["x", "y"])
        #expect(WikilinkSyntax.links(in: text, excluding: [code]).map(\.target) == ["y"])
    }

    @Test func rangesUseUTF16Coordinates() throws {
        // An emoji is two UTF-16 units; ranges must still land on the brackets.
        let text = "🙂 see [[Plan]]"
        let link = try single(text)
        #expect((text as NSString).substring(with: link.range) == "[[Plan]]")
        #expect((text as NSString).substring(with: link.targetRange) == "Plan")
    }

    @Test func parseInnerMatchesLinks() {
        let parts = WikilinkSyntax.parse(inner: "Plan#Budget|see")
        #expect(parts.target == "Plan")
        #expect(parts.heading == "Budget")
        #expect(parts.blockId == nil)
        #expect(parts.alias == "see")
    }

    // MARK: Rewrite

    @Test func rewriteKeepsAliasHeadingPathAndWhitespace() {
        let text = "[[Old]] [[Old|the plan]] [[Old#H]] [[Projects/Old#H|x]] [[ Old ]] ![[Old]] [[Old#^abc]]"
        let result = WikilinkSyntax.rewrite(text, renamingTitle: "Old", to: "New 2026")
        #expect(result.count == 7)
        #expect(result.text == "[[New 2026]] [[New 2026|the plan]] [[New 2026#H]] "
            + "[[Projects/New 2026#H|x]] [[ New 2026 ]] ![[New 2026]] [[New 2026#^abc]]")
    }

    @Test func rewriteIsCaseInsensitiveOnMatchExactOnReplacement() {
        let result = WikilinkSyntax.rewrite("[[old]] and [[OLD|x]]", renamingTitle: "Old", to: "NeW")
        #expect(result.text == "[[NeW]] and [[NeW|x]]")
        #expect(result.count == 2)
    }

    @Test func rewriteSkipsSelfHeadingAndExcluded() {
        let text = "[[#Old]] `[[Old]]` [[Old]]"
        let code = NSRange(location: 9, length: 9)
        let result = WikilinkSyntax.rewrite(text, renamingTitle: "Old", to: "New", excluding: [code])
        #expect(result.text == "[[#Old]] `[[Old]]` [[New]]")
        #expect(result.count == 1)
    }

    @Test func rewriteIsIdempotentAndCountsOnlyChanges() {
        let first = WikilinkSyntax.rewrite("[[Old]] [[New]] [[Old|x]]", renamingTitle: "Old", to: "New")
        #expect(first.text == "[[New]] [[New]] [[New|x]]")
        #expect(first.count == 2, "the link that already says New is not a change")
        let second = WikilinkSyntax.rewrite(first.text, renamingTitle: "Old", to: "New")
        #expect(second.text == first.text)
        #expect(second.count == 0)
    }

    @Test func rewriteDoesNotTouchOtherTitles() {
        let text = "[[Plans]] [[Plan]] [[Old Plan]] [[Projects/Plans]]"
        let result = WikilinkSyntax.rewrite(text, renamingTitle: "Plan", to: "Roadmap")
        #expect(result.text == "[[Plans]] [[Roadmap]] [[Old Plan]] [[Projects/Plans]]")
        #expect(result.count == 1)
    }

    @Test func rewriteHandlesCaseOnlyRename() {
        let result = WikilinkSyntax.rewrite("[[plan]] [[Plan]]", renamingTitle: "plan", to: "Plan")
        #expect(result.text == "[[Plan]] [[Plan]]")
        #expect(result.count == 1)
    }

    @Test func rewriteRefusesEmptyNames() {
        #expect(WikilinkSyntax.rewrite("[[Old]]", renamingTitle: "", to: "New").count == 0)
        #expect(WikilinkSyntax.rewrite("[[Old]]", renamingTitle: "Old", to: "  ").count == 0)
    }

    @Test func rewriteSurvivesNonBMPText() {
        let result = WikilinkSyntax.rewrite("🙂 [[Old]] 🙂 [[Old|🙂]]", renamingTitle: "Old", to: "New")
        #expect(result.text == "🙂 [[New]] 🙂 [[New|🙂]]")
        #expect(result.count == 2)
    }

    // MARK: Resolve

    private let notes: [(id: String, title: String)] = [
        ("Plan.md", "Plan"),
        ("Projects/Plan.md", "Plan"),
        ("Projects/Deep/Plan.md", "Plan"),
        ("Areas/Plan.md", "Plan"),
        ("Areas/Budget.md", "Budget"),
        ("Inbox/Solo.md", "Solo"),
    ]

    private func link(_ text: String) throws -> Wikilink {
        try single(text)
    }

    @Test func resolvePrefersPathThenSameFolderThenShortestId() throws {
        // Path wins over everything, case-insensitively.
        #expect(try WikilinkSyntax.resolve(link("[[Projects/Plan]]"), among: notes, from: "Areas/Budget.md")
            == "Projects/Plan.md")
        #expect(try WikilinkSyntax.resolve(link("[[projects/deep/plan]]"), among: notes, from: nil)
            == "Projects/Deep/Plan.md")
        // Same folder as the source note.
        #expect(try WikilinkSyntax.resolve(link("[[Plan]]"), among: notes, from: "Projects/Other.md")
            == "Projects/Plan.md")
        #expect(try WikilinkSyntax.resolve(link("[[plan]]"), among: notes, from: "Areas/Budget.md")
            == "Areas/Plan.md")
        // No same-folder match: the shortest id.
        #expect(try WikilinkSyntax.resolve(link("[[Plan]]"), among: notes, from: "Inbox/Solo.md")
            == "Plan.md")
        #expect(try WikilinkSyntax.resolve(link("[[Plan]]"), among: notes, from: nil) == "Plan.md")
        // A single candidate resolves, alias and heading ignored.
        #expect(try WikilinkSyntax.resolve(link("[[solo#H|x]]"), among: notes, from: "Plan.md")
            == "Inbox/Solo.md")
        // A path that doesn't exist falls back to the title.
        #expect(try WikilinkSyntax.resolve(link("[[Old Folder/Budget]]"), among: notes, from: nil)
            == "Areas/Budget.md")
    }

    @Test func resolveBreaksIdTiesLexicographically() throws {
        let tied: [(id: String, title: String)] = [("B/Plan.md", "Plan"), ("A/Plan.md", "Plan")]
        #expect(try WikilinkSyntax.resolve(link("[[Plan]]"), among: tied, from: nil) == "A/Plan.md")
    }

    @Test func resolveReturnsNilWhenUnknown() throws {
        #expect(try WikilinkSyntax.resolve(link("[[Nope]]"), among: notes, from: nil) == nil)
        #expect(try WikilinkSyntax.resolve(link("[[#Heading]]"), among: notes, from: "Plan.md") == nil)
        #expect(try WikilinkSyntax.resolve(link("[[Plan]]"), among: [], from: nil) == nil)
    }

    // MARK: Anchors

    private let document = """
    ---
    # not a heading, it's YAML
    title: x
    ---
    # Plan

    Intro line ^intro1

    ## Budget

    Spend ^abc12

    ```
    # not a heading, it's code
    ^abc12
    ```

    ### Budget notes ###
    Also text^notablock
    """

    @Test func anchorLineFindsHeadingCaseInsensitive() {
        #expect(WikilinkSyntax.anchorLine(heading: "budget", blockId: nil, in: document) == 8)
        #expect(WikilinkSyntax.anchorLine(heading: "Plan", blockId: nil, in: document) == 4)
        #expect(WikilinkSyntax.anchorLine(heading: "  PLAN ", blockId: nil, in: document) == 4)
    }

    @Test func anchorLineFindsBlockId() {
        #expect(WikilinkSyntax.anchorLine(heading: nil, blockId: "abc12", in: document) == 10)
        #expect(WikilinkSyntax.anchorLine(heading: nil, blockId: "intro1", in: document) == 6)
    }

    @Test func anchorLineMissingIsNil() {
        #expect(WikilinkSyntax.anchorLine(heading: "Nope", blockId: nil, in: document) == nil)
        #expect(WikilinkSyntax.anchorLine(heading: nil, blockId: "zzz", in: document) == nil)
        #expect(WikilinkSyntax.anchorLine(heading: nil, blockId: nil, in: document) == nil)
        #expect(WikilinkSyntax.anchorLine(heading: "", blockId: "", in: document) == nil)
        // Skipped regions: YAML comment, fenced code, a "^id" glued to a word.
        #expect(WikilinkSyntax.anchorLine(heading: "not a heading, it's YAML", blockId: nil, in: document) == nil)
        #expect(WikilinkSyntax.anchorLine(heading: "not a heading, it's code", blockId: nil, in: document) == nil)
        #expect(WikilinkSyntax.anchorLine(heading: nil, blockId: "notablock", in: document) == nil)
    }

    @Test func anchorLineCountsFromTheTopWithCRLF() {
        let text = "intro\r\n\r\n## Budget\r\nSpend ^abc12\r\n"
        #expect(WikilinkSyntax.anchorLine(heading: "Budget", blockId: nil, in: text) == 2)
        #expect(WikilinkSyntax.anchorLine(heading: nil, blockId: "abc12", in: text) == 3)
    }
}

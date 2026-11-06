import Foundation
@testable import TaskEngine
import Testing

/// The rewriter edits the token the parser reads. Both must share ONE
/// vocabulary string (`TaskTokenParser.priorityTokenPattern` /
/// `kindTokenPattern`), or a token the parser accepts (`!med`) gets a second
/// token appended instead of being replaced (spec 06e).
struct TaskLineRewriterParityTests {
    private static let priorityAliases = ["p1", "p2", "p3", "p4", "high", "medium", "med", "low"]
    private static let kinds = ["discuss", "waiting", "next", "someday", "followup"]

    /// Number of `!priority` tokens the parser's own geometry finds on a line.
    private func priorityTokenCount(in line: String) -> Int {
        let ns = line as NSString
        return TaskTokenParser.tokenRanges(in: line)
            .map { ns.substring(with: $0) }
            .filter { $0.hasPrefix("!") }
            .count
    }

    @Test(arguments: priorityAliases)
    func settingPriorityReplacesEveryAliasParserAccepts(alias: String) {
        let line = "- [ ] task !\(alias) #t"
        #expect(TaskTokenParser.parse(line).priority != nil, "parser accepts !\(alias)")
        for newPriority in 1 ... 4 {
            let out = TaskLineRewriter.settingPriority(line, to: newPriority)
            #expect(out == "- [ ] task !p\(newPriority) #t", "!\(alias) → !p\(newPriority)")
            #expect(priorityTokenCount(in: out) == 1, "exactly one ! token in: \(out)")
            #expect(TaskTokenParser.parse(out).priority == newPriority)
        }
    }

    @Test func settingPriorityReplacesUppercaseAlias() {
        #expect(TaskLineRewriter.settingPriority("- [ ] x !MED", to: 1) == "- [ ] x !p1")
        #expect(TaskLineRewriter.settingPriority("- [ ] x !High", to: 4) == "- [ ] x !p4")
    }

    @Test func medNoLongerAppendsASecondToken() {
        let out = TaskLineRewriter.settingPriority("- [ ] x !med", to: 1)
        #expect(out == "- [ ] x !p1")
        #expect(!out.contains("!med"))
    }

    @Test(arguments: priorityAliases)
    func removingPriorityStripsEveryAlias(alias: String) {
        let out = TaskLineRewriter.settingPriority("- [ ] task !\(alias) #t", to: nil)
        #expect(out == "- [ ] task #t")
        #expect(TaskTokenParser.parse(out).priority == nil)
    }

    @Test func removingPriorityStripsMedAlias() {
        #expect(TaskLineRewriter.settingPriority("- [ ] x !med", to: nil) == "- [ ] x")
        #expect(TaskLineRewriter.settingPriority("- [ ] x !medium", to: nil) == "- [ ] x")
    }

    @Test func settingPriorityLeavesLongerWordsAlone() {
        // `\b` after the alias: `!medical` is prose, not a priority token.
        let line = "- [ ] x !medical"
        #expect(TaskLineRewriter.settingPriority(line, to: 2) == "- [ ] x !medical !p2")
    }

    @Test(arguments: kinds)
    func settingKindReplacesEveryVocabularyWord(kind: String) {
        for replacement in Self.kinds {
            let out = TaskLineRewriter.settingKind("- [ ] topic ?\(kind) @a", to: replacement)
            #expect(out == "- [ ] topic ?\(replacement) @a")
            #expect(TaskTokenParser.parse(out).kind == replacement)
        }
        #expect(TaskLineRewriter.settingKind("- [ ] topic ?\(kind)", to: nil) == "- [ ] topic")
    }

    @Test func rewriterPatternsAreParserPatterns() {
        #expect(TaskLineRewriter.priorityRegex?.pattern == TaskTokenParser.priorityTokenPattern)
        #expect(TaskLineRewriter.kindRegex?.pattern == TaskTokenParser.kindTokenPattern)
        #expect(TaskTokenParser.priorityRegex?.pattern == TaskTokenParser.priorityTokenPattern)
        #expect(TaskTokenParser.kindRegex?.pattern == TaskTokenParser.kindTokenPattern)
        // Both are case-insensitive in both places.
        #expect(TaskLineRewriter.priorityRegex?.options.contains(.caseInsensitive) == true)
        #expect(TaskLineRewriter.kindRegex?.options.contains(.caseInsensitive) == true)
        #expect(TaskTokenParser.priorityRegex?.options == TaskLineRewriter.priorityRegex?.options)
        #expect(TaskTokenParser.kindRegex?.options == TaskLineRewriter.kindRegex?.options)
    }
}

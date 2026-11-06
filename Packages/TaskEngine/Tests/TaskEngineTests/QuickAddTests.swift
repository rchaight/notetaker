import Foundation
@testable import TaskEngine
import Testing

struct QuickAddTests {
    /// Sunday 2026-07-12, noon UTC.
    private var today: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 12; components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func explicitTokensPassThrough() {
        let result = QuickAddParser.parse("email dean >2026-07-20 !p1 #admin")
        #expect(result?.markdownLine == "- [ ] email dean #admin >2026-07-20 !p1")
        #expect(result?.metadata.dueDate == "2026-07-20")
        #expect(result?.metadata.priority == 1)
        #expect(result?.metadata.labels == ["admin"])
    }

    @Test func naturalTomorrowDetected() {
        let result = QuickAddParser.parse("call plumber tomorrow")
        #expect(result?.metadata.dueDate == SmartBuckets.isoDay(offsetFromToday: 1))
        #expect(result?.metadata.cleanText == "call plumber")
    }

    @Test func barePriorityDetected() {
        let result = QuickAddParser.parse("review grant p2")
        #expect(result?.metadata.priority == 2)
        #expect(result?.metadata.cleanText == "review grant")
        #expect(result?.markdownLine == "- [ ] review grant !p2")
    }

    @Test func recurrenceCarriedIntoLine() {
        let result = QuickAddParser.parse("water plants >2026-07-14 &every 3 days")
        #expect(result?.markdownLine == "- [ ] water plants >2026-07-14 &every 3 days")
    }

    @Test func plainTextStaysPlain() {
        let result = QuickAddParser.parse("just a thought")
        #expect(result?.markdownLine == "- [ ] just a thought")
        #expect(result?.metadata.dueDate == nil)
    }

    @Test func emptyAndWhitespaceRejected() {
        #expect(QuickAddParser.parse("") == nil)
        #expect(QuickAddParser.parse("   \n") == nil)
        #expect(QuickAddParser.parse(">tomorrow !p1") == nil, "metadata with no text is not a task")
    }

    // MARK: - Every token survives (spec 03)

    private func line(_ input: String) -> String? {
        QuickAddParser.parse(input, today: today, calendar: calendar)?.markdownLine
    }

    @Test func assigneeKept() {
        #expect(line("call Amber @Amber") == "- [ ] call Amber @Amber")
    }

    @Test func kindKept() {
        #expect(line("budget ?discuss @Amber") == "- [ ] budget @Amber ?discuss")
    }

    @Test(arguments: ["discuss", "waiting", "next", "someday", "followup"])
    func everyKindInVocabulary(kind: String) {
        #expect(line("thing ?\(kind)") == "- [ ] thing ?\(kind)")
        #expect(QuickAddParser.parse("thing ?\(kind)", today: today, calendar: calendar)?.metadata.kind == kind)
    }

    @Test func unknownKindStaysInText() {
        let result = QuickAddParser.parse("thing ?bogus", today: today, calendar: calendar)
        #expect(result?.markdownLine == "- [ ] thing ?bogus")
        #expect(result?.metadata.kind == nil)
    }

    @Test func startDateKept() {
        #expect(line("draft ~2026-07-01 >2026-07-10") == "- [ ] draft >2026-07-10 ~2026-07-01")
    }

    @Test func blockIdKept() {
        #expect(line("ship ^ship-v1") == "- [ ] ship ^ship-v1")
    }

    @Test func dependencyKeptAndNormalised() {
        // `depends:` and `blockedby:` are synonyms to the parser; the
        // canonical serialisation (shared with Task Detail) is `blockedby:`.
        #expect(line("test depends:^ship-v1") == "- [ ] test blockedby:^ship-v1")
        #expect(line("test blockedby:^ship-v1") == "- [ ] test blockedby:^ship-v1")
    }

    @Test func multipleDependencies() {
        #expect(line("x blockedby:^a,^b") == "- [ ] x blockedby:^a blockedby:^b")
    }

    @Test func completedDayKept() {
        #expect(line("done ✅2026-07-01") == "- [ ] done ✅2026-07-01")
    }

    private let allTokens = "- [ ] t #tag >2026-07-10 ~2026-07-05 !p2 &every 2 weeks ^id blockedby:^o @p ?waiting"

    @Test func allTokensCanonicalOrder() {
        let scrambled = "?waiting @p blockedby:^o ^id &every 2 weeks !p2 ~2026-07-05 >2026-07-10 t #tag"
        #expect(line(scrambled) == allTokens)
    }

    @Test func orderIndependent() {
        let a = line("t #tag >2026-07-10 ~2026-07-05 !p2 &every 2 weeks ^id blockedby:^o @p ?waiting")
        let b = line("@p ?waiting !p2 t #tag ^id >2026-07-10 blockedby:^o ~2026-07-05 &every 2 weeks")
        #expect(a != nil)
        #expect(a == b)
        #expect(a == allTokens)
    }

    @Test func idempotent() throws {
        let inputs = [
            "call Amber @Amber", "budget ?discuss @Amber", "draft ~2026-07-01 >2026-07-10",
            "ship ^ship-v1", "test depends:^ship-v1", "x blockedby:^a,^b", "done ✅2026-07-01",
            "?waiting @p blockedby:^o ^id &every 2 weeks !p2 ~2026-07-05 >2026-07-10 t #tag",
            "email dean >2026-07-20 !p1 #admin", "water plants >2026-07-14 &every 3 days",
            "thing ?bogus", "just a thought",
        ]
        for input in inputs {
            let first = try #require(line(input), "\(input)")
            let body = String(first.dropFirst("- [ ] ".count))
            #expect(line(body) == first, "re-parsing must not change: \(input)")
        }
    }

    @Test func naturalDateDoesNotOverrideToken() throws {
        let result = try #require(QuickAddParser.parse(
            "pay rent tomorrow >2026-07-20", today: today, calendar: calendar
        ))
        #expect(result.metadata.dueDate == "2026-07-20")
        #expect(result.markdownLine == "- [ ] pay rent tomorrow >2026-07-20")
    }

    @Test func barePriorityDoesNotOverrideToken() throws {
        let result = try #require(QuickAddParser.parse("x p1 !p3", today: today, calendar: calendar))
        #expect(result.metadata.priority == 3)
        #expect(result.markdownLine == "- [ ] x p1 !p3")
    }

    @Test func hasExplicitTokensTable() {
        let explicit = [
            ">2026-07-10", ">tomorrow", "~2026-07-01", "!p1", "!high", "&every week", "&after 2 days",
            "^ship-v1", "blockedby:^a", "depends:^a", "@Amber", "?waiting", "✅2026-07-01",
            "call Amber @Amber", "x ?discuss",
        ]
        for input in explicit {
            #expect(QuickAddParser.hasExplicitTokens(input), "should be explicit: \(input)")
        }
        let plain = [
            "plain text", "call plumber tomorrow", "review grant p2", "#tag only", "what? ok",
            "email dean@school.edu", "a > b", "wow !pizza", "ask ?bogus", "",
        ]
        for input in plain {
            #expect(!QuickAddParser.hasExplicitTokens(input), "should be plain: \(input)")
        }
    }

    @Test func metadataCarriesAllFields() throws {
        let result = try #require(QuickAddParser.parse(
            "?waiting @p blockedby:^o ^id &every 2 weeks !p2 ~2026-07-05 >2026-07-10 ✅2026-07-01 t #tag",
            today: today, calendar: calendar
        ))
        let meta = result.metadata
        #expect(meta.cleanText == "t #tag")
        #expect(meta.dueDate == "2026-07-10")
        #expect(meta.startDate == "2026-07-05")
        #expect(meta.priority == 2)
        #expect(meta.labels == ["tag"])
        #expect(meta.recurrence?.rawToken == "&every 2 weeks")
        #expect(meta.blockId == "id")
        #expect(meta.dependsOn == ["o"])
        #expect(meta.completedDay == "2026-07-01")
        #expect(meta.assignee == "p")
        #expect(meta.kind == "waiting")
        // The serialised line re-parses to the same metadata.
        let reparsed = TaskTokenParser.parse(
            String(result.markdownLine.dropFirst("- [ ] ".count)), today: today, calendar: calendar
        )
        #expect(reparsed == meta)
    }

    @Test func tokenSuffixMatchesCanonicalOrder() {
        let meta = TaskTokenParser.parse(
            "t >2026-07-10 ~2026-07-05 !p2 &every 2 weeks ^id blockedby:^a,^b @p ?waiting ✅2026-07-01",
            today: today, calendar: calendar
        )
        #expect(meta.tokenSuffix == [
            ">2026-07-10", "~2026-07-05", "!p2", "&every 2 weeks", "^id",
            "blockedby:^a", "blockedby:^b", "@p", "?waiting", "✅2026-07-01",
        ])
        #expect(TaskTokenParser.parse("plain", today: today, calendar: calendar).tokenSuffix.isEmpty)
    }
}

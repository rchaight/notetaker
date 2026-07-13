import Foundation
@testable import TaskEngine
import Testing

struct TaskTokenParserTests {
    /// Friday 2026-07-10, noon UTC.
    private var friday: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 10; components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func parsesAbsoluteDate() {
        let parsed = TaskTokenParser.parse("call the dean >2026-07-15", today: friday, calendar: utcCalendar)
        #expect(parsed.dueDate == "2026-07-15")
        #expect(parsed.cleanText == "call the dean")
    }

    @Test func parsesTodayAndTomorrow() {
        #expect(TaskTokenParser.parse("x >today", today: friday, calendar: utcCalendar).dueDate == "2026-07-10")
        #expect(TaskTokenParser.parse("x >tomorrow", today: friday, calendar: utcCalendar).dueDate == "2026-07-11")
    }

    @Test func weekdayResolvesToNextOccurrence() {
        // Today is Friday: >monday = next Monday (2026-07-13); >friday = NEXT Friday.
        #expect(TaskTokenParser.parse("x >monday", today: friday, calendar: utcCalendar).dueDate == "2026-07-13")
        #expect(TaskTokenParser.parse("x >friday", today: friday, calendar: utcCalendar).dueDate == "2026-07-17")
    }

    @Test func parsesPriorities() {
        #expect(TaskTokenParser.parse("x !p1").priority == 1)
        #expect(TaskTokenParser.parse("x !high").priority == 1)
        #expect(TaskTokenParser.parse("x !medium").priority == 2)
        #expect(TaskTokenParser.parse("x !low").priority == 3)
        #expect(TaskTokenParser.parse("x !p4").priority == 4)
        #expect(TaskTokenParser.parse("no priority here").priority == nil)
    }

    @Test func extractsLabelsKeepsThemInText() {
        let parsed = TaskTokenParser.parse("review #phar7315 syllabus #teaching >2026-08-01 !p2")
        #expect(parsed.labels == ["phar7315", "teaching"])
        #expect(parsed.dueDate == "2026-08-01")
        #expect(parsed.priority == 2)
        #expect(parsed.cleanText == "review #phar7315 syllabus #teaching")
    }

    @Test func plainTextPassesThrough() {
        let parsed = TaskTokenParser.parse("just a simple task")
        #expect(parsed == ParsedTaskMetadata(
            cleanText: "just a simple task", dueDate: nil, priority: nil, labels: []
        ))
    }
}

struct DependencyTokenTests {
    @Test func blockIdParsesAndCleans() {
        let parsed = TaskTokenParser.parse("design the API ^design-api >2026-08-01")
        #expect(parsed.blockId == "design-api")
        #expect(parsed.cleanText == "design the API")
        #expect(parsed.dueDate == "2026-08-01")
    }

    @Test func dependsAndBlockedByParse() {
        let one = TaskTokenParser.parse("build it depends:^design-api")
        #expect(one.dependsOn == ["design-api"])
        #expect(one.cleanText == "build it")
        let two = TaskTokenParser.parse("ship blockedby:design,build !p1")
        #expect(two.dependsOn == ["design", "build"])
        #expect(two.cleanText == "ship")
        #expect(two.priority == 1)
    }

    @Test func caretInMathDoesNotFalselyMatch() {
        let parsed = TaskTokenParser.parse("compute 2^10 quickly")
        // "^10"-style mid-word carets are preceded by non-space; only
        // whitespace-anchored ^ids count.
        #expect(parsed.blockId == nil)
        #expect(parsed.cleanText == "compute 2^10 quickly")
    }

    @Test func plainTasksUnaffected() {
        let parsed = TaskTokenParser.parse("simple task >today #tag")
        #expect(parsed.blockId == nil)
        #expect(parsed.dependsOn.isEmpty)
    }
}

struct TaskLineRewriterTests {
    @Test func replacesExistingDueToken() {
        #expect(TaskLineRewriter.settingDueDate("- [ ] call dean >2026-07-10 !p1", to: "2026-07-15")
            == "- [ ] call dean >2026-07-15 !p1")
        #expect(TaskLineRewriter.settingDueDate("- [ ] soon >tomorrow", to: "2026-08-01")
            == "- [ ] soon >2026-08-01")
    }

    @Test func appendsWhenAbsentAndRemovesOnNil() {
        #expect(TaskLineRewriter.settingDueDate("- [ ] bare task", to: "2026-07-15")
            == "- [ ] bare task >2026-07-15")
        #expect(TaskLineRewriter.settingDueDate("- [ ] dated >2026-07-15 #tag", to: nil)
            == "- [ ] dated #tag")
    }

    @Test func startTokenAndCRLFSurvive() {
        #expect(TaskLineRewriter.settingStartDate("- [ ] slow burn ~2026-07-01", to: "2026-07-05")
            == "- [ ] slow burn ~2026-07-05")
        #expect(TaskLineRewriter.settingDueDate("- [ ] windows line\r", to: "2026-07-15")
            == "- [ ] windows line >2026-07-15\r")
    }

    @Test func rewriteRoundTripsThroughParser() {
        let rewritten = TaskLineRewriter.settingDueDate("- [ ] ship it depends:^build !p2", to: "2026-09-01")
        let parsed = TaskTokenParser.parse(String(rewritten.dropFirst(6)))
        #expect(parsed.dueDate == "2026-09-01")
        #expect(parsed.priority == 2)
        #expect(parsed.dependsOn == ["build"])
    }
}

struct DependencyRewriteTests {
    @Test func ensuresBlockIdWithSlug() {
        let (line, id) = TaskLineRewriter.ensuringBlockId("- [ ] Design the API! >2026-08-01")
        #expect(id == "design-the-api")
        #expect(line == "- [ ] Design the API! >2026-08-01 ^design-the-api")
        let (unchanged, existing) = TaskLineRewriter.ensuringBlockId("- [ ] built ^build")
        #expect(existing == "build")
        #expect(unchanged == "- [ ] built ^build")
    }

    @Test func addsDependencyOnceOnly() {
        let once = TaskLineRewriter.addingDependency("- [ ] ship it", on: "build")
        #expect(once == "- [ ] ship it blockedby:^build")
        #expect(TaskLineRewriter.addingDependency(once, on: "build") == once)
    }
}

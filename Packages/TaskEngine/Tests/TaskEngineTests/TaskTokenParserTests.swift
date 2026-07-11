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

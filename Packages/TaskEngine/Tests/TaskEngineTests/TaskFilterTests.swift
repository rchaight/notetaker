import Foundation
@testable import TaskEngine
import Testing

struct TaskFilterTests {
    private var noon: Date {
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

    @Test func parsesMixedQuery() {
        let filter = TaskFilter.parse("p1 due:today #admin report note:inbox")
        #expect(filter.predicates == [
            .priority(1), .due(.today), .label("admin"),
            .textContains("report"), .note("inbox"),
        ])
    }

    @Test func andKeywordIgnoredAndPriorityForms() {
        let filter = TaskFilter.parse("priority:p2 AND due:overdue")
        #expect(filter.predicates == [.priority(2), .due(.overdue)])
    }

    @Test func matchesAllPredicates() {
        let filter = TaskFilter.parse("p1 #admin dean")
        #expect(filter.matches(
            text: "email the dean #admin", noteId: "Work/plan.md",
            dueDate: nil, priority: 1, labels: ["admin"],
            today: noon, calendar: calendar
        ))
        #expect(!filter.matches(
            text: "email the dean #admin", noteId: "Work/plan.md",
            dueDate: nil, priority: 2, labels: ["admin"],
            today: noon, calendar: calendar
        ))
    }

    @Test func dueTermsEvaluate() {
        let today = TaskFilter.parse("due:today")
        #expect(today.matches(text: "x", noteId: "n", dueDate: "2026-07-12",
                              priority: nil, labels: [], today: noon, calendar: calendar))
        let overdue = TaskFilter.parse("due:overdue")
        #expect(overdue.matches(text: "x", noteId: "n", dueDate: "2026-07-01",
                                priority: nil, labels: [], today: noon, calendar: calendar))
        let none = TaskFilter.parse("due:none")
        #expect(none.matches(text: "x", noteId: "n", dueDate: nil,
                             priority: nil, labels: [], today: noon, calendar: calendar))
        let week = TaskFilter.parse("due:week")
        #expect(week.matches(text: "x", noteId: "n", dueDate: "2026-07-15",
                             priority: nil, labels: [], today: noon, calendar: calendar))
        #expect(!week.matches(text: "x", noteId: "n", dueDate: "2026-08-15",
                              priority: nil, labels: [], today: noon, calendar: calendar))
    }

    @Test func emptyQueryMatchesEverything() {
        let filter = TaskFilter.parse("  ")
        #expect(filter.isEmpty)
        #expect(filter.matches(text: "anything", noteId: "n", dueDate: nil,
                               priority: nil, labels: [], today: noon, calendar: calendar))
    }
}

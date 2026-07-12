import Foundation
@testable import TaskEngine
import Testing

/// Tests added from the model-tiered coverage audit (pass 46).
struct EngineAuditHardeningTests {
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

    @Test func zeroAndNegativeIntervalsNeverParse() {
        var zero = "x &every 0 days"
        #expect(RecurrenceParser.extract(from: &zero) == nil)
        #expect(zero == "x &every 0 days", "rejected token stays visible in text")
    }

    @Test(.timeLimit(.minutes(1))) func degenerateRuleCannotHang() {
        // Even if a zero-interval rule is constructed directly, the catch-up
        // loop must terminate.
        let rule = Recurrence(kind: .fixed, interval: 0, unit: .day, weekday: nil, rawToken: "&every 0 days")
        _ = RecurrenceEngine.nextDueDate(
            recurrence: rule, currentDue: "2020-01-01", completedOn: today, calendar: calendar
        )
    }

    @Test func impossibleDatesAreNotConsumed() {
        let parsed = TaskTokenParser.parse("pay bill >2026-13-45", today: today, calendar: calendar)
        #expect(parsed.dueDate == nil, "garbage dates must not become metadata")
        #expect(parsed.cleanText.contains(">2026-13-45"), "the bogus token stays visible for the user to fix")
        #expect(SmartBuckets.bucket(dueDate: parsed.dueDate, today: today, calendar: calendar) == .inbox)
    }

    @Test func monthEndRecurrenceClampsPredictably() throws {
        let rule = Recurrence(kind: .fixed, interval: 1, unit: .month, weekday: nil, rawToken: "&every month")
        var jan31 = DateComponents()
        jan31.year = 2026; jan31.month = 2; jan31.day = 1; jan31.hour = 12
        jan31.timeZone = TimeZone(identifier: "UTC")
        let completed = try #require(Calendar(identifier: .gregorian).date(from: jan31))
        let next = RecurrenceEngine.nextDueDate(
            recurrence: rule, currentDue: "2026-01-31", completedOn: completed, calendar: calendar
        )
        #expect(next == "2026-02-28", "Calendar clamps month-end — locked as documented behavior")
    }

    @Test func dueWeekExcludesOverdue() {
        let filter = TaskFilter.parse("due:week")
        #expect(!filter.matches(text: "x", noteId: "n", dueDate: "2026-07-01",
                                priority: nil, labels: [], today: today, calendar: calendar),
                "due:week means today through +7, never overdue")
        #expect(filter.matches(text: "x", noteId: "n", dueDate: "2026-07-12",
                               priority: nil, labels: [], today: today, calendar: calendar))
    }

    @Test func duplicateTokensOnlyFirstConsumed() {
        let parsed = TaskTokenParser.parse("x >2026-07-15 >2026-08-01 !p1 !p3", today: today, calendar: calendar)
        #expect(parsed.dueDate == "2026-07-15")
        #expect(parsed.priority == 1)
        #expect(parsed.cleanText.contains(">2026-08-01"), "second date token remains as text")
        #expect(parsed.cleanText.contains("!p3"), "second priority token remains as text")
    }
}

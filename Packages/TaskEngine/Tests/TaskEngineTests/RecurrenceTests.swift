import Foundation
@testable import TaskEngine
import Testing

struct RecurrenceTests {
    /// Saturday 2026-07-11, noon UTC.
    private var today: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 11; components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func parsesEveryVariants() {
        var text = "water plants &every 3 days"
        let recurrence = RecurrenceParser.extract(from: &text)
        #expect(recurrence == Recurrence(
            kind: .fixed, interval: 3, unit: .day, weekday: nil, rawToken: "&every 3 days"
        ))
        #expect(text.trimmingCharacters(in: .whitespaces) == "water plants")

        var weekly = "report &every week"
        #expect(RecurrenceParser.extract(from: &weekly)?.unit == .week)

        var friday = "review &every friday"
        let fridayRule = RecurrenceParser.extract(from: &friday)
        #expect(fridayRule?.weekday == 6)
        #expect(fridayRule?.kind == .fixed)
    }

    @Test func parsesAfterCompletion() {
        var text = "trim beard &after 7 days"
        let recurrence = RecurrenceParser.extract(from: &text)
        #expect(recurrence?.kind == .afterCompletion)
        #expect(recurrence?.interval == 7)
    }

    @Test func tokenParserCarriesRecurrence() {
        let parsed = TaskTokenParser.parse("water plants >2026-07-12 &every 3 days", today: today, calendar: calendar)
        #expect(parsed.recurrence?.rawToken == "&every 3 days")
        #expect(parsed.dueDate == "2026-07-12")
        #expect(parsed.cleanText == "water plants")
    }

    @Test func fixedNextDateAdvancesFromDue() {
        let rule = Recurrence(kind: .fixed, interval: 3, unit: .day, weekday: nil, rawToken: "&every 3 days")
        let next = RecurrenceEngine.nextDueDate(
            recurrence: rule, currentDue: "2026-07-10", completedOn: today, calendar: calendar
        )
        #expect(next == "2026-07-13")
    }

    @Test func fixedCatchesUpLongOverdueSeries() {
        let rule = Recurrence(kind: .fixed, interval: 1, unit: .week, weekday: nil, rawToken: "&every week")
        let next = RecurrenceEngine.nextDueDate(
            recurrence: rule, currentDue: "2026-06-01", completedOn: today, calendar: calendar
        )
        #expect(next == "2026-07-13", "series catches up past completion, never emits past dates")
    }

    @Test func afterCompletionCountsFromToday() {
        let rule = Recurrence(kind: .afterCompletion, interval: 7, unit: .day, weekday: nil, rawToken: "&after 7 days")
        let next = RecurrenceEngine.nextDueDate(
            recurrence: rule, currentDue: "2026-07-01", completedOn: today, calendar: calendar
        )
        #expect(next == "2026-07-18")
    }

    @Test func weekdayRuleFindsNextOccurrence() {
        let rule = Recurrence(kind: .fixed, interval: 1, unit: nil, weekday: 6, rawToken: "&every friday")
        let next = RecurrenceEngine.nextDueDate(
            recurrence: rule, currentDue: nil, completedOn: today, calendar: calendar
        )
        #expect(next == "2026-07-17", "Saturday completion → next Friday")
    }

    @Test func completingRecurringLineAdvancesDateStaysOpen() {
        let line = "- [ ] water plants >2026-07-10 &every 3 days"
        let completed = RecurrenceEngine.completeTaskLine(line, today: today, calendar: calendar)
        #expect(completed == "- [ ] water plants >2026-07-13 &every 3 days")
    }

    @Test func completingRecurringLineWithoutDateAppendsOne() {
        let line = "- [ ] stretch &after 1 day"
        let completed = RecurrenceEngine.completeTaskLine(line, today: today, calendar: calendar)
        #expect(completed == "- [ ] stretch &after 1 day >2026-07-12")
    }

    @Test func nonRecurringLineJustFlips() {
        #expect(RecurrenceEngine.completeTaskLine("- [ ] once", today: today, calendar: calendar) == "- [x] once")
        #expect(RecurrenceEngine.completeTaskLine("- [x] once", today: today, calendar: calendar) == "- [ ] once")
    }

    @Test func completeTaskSplicesWholeDocument() {
        let text = "# Chores\n\n- [ ] water plants >2026-07-10 &every 3 days\n- [ ] once\n"
        let ns = text as NSString
        let tokenRange = ns.range(of: "[ ]") // first checkbox
        let updated = RecurrenceEngine.completeTask(in: text, tokenRange: tokenRange, today: today, calendar: calendar)
        #expect(updated == "# Chores\n\n- [ ] water plants >2026-07-13 &every 3 days\n- [ ] once\n")
    }
}

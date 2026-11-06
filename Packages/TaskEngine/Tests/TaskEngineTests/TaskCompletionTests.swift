import Foundation
@testable import TaskEngine
import Testing

/// The one completion primitive every surface calls: `[ ]` → `[x] … ✅day`,
/// `[x]` → `[ ]` with the stamp stripped, recurring → date advances and the
/// box stays open (spec 02).
struct TaskCompletionTests {
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

    private let day = "2026-07-11"

    private func complete(_ line: String) -> String? {
        RecurrenceEngine.completeTaskLine(line, today: today, calendar: calendar)
    }

    @Test func checkStampsToday() {
        #expect(complete("- [ ] once") == "- [x] once ✅\(day)")
    }

    @Test func checkThenUncheckRoundTrips() throws {
        let checked = try #require(complete("- [ ] once"))
        #expect(complete(checked) == "- [ ] once")
    }

    @Test func checkReplacesStaleStamp() {
        #expect(complete("- [ ] once ✅2020-01-01") == "- [x] once ✅\(day)")
    }

    @Test func uncheckStripsStamp() {
        #expect(complete("- [x] once ✅2026-07-10") == "- [ ] once")
    }

    @Test func uncheckWithoutStampJustFlips() {
        #expect(complete("- [X] once") == "- [ ] once")
        #expect(complete("- [x] once") == "- [ ] once")
    }

    @Test func stampKeepsTrailingWhitespaceAndCR() {
        #expect(complete("- [ ] once  \r") == "- [x] once ✅\(day)  \r")
        #expect(complete("- [ ] once\r") == "- [x] once ✅\(day)\r")
    }

    @Test func uncheckKeepsTrailingCR() {
        #expect(complete("- [x] once ✅2026-07-10\r") == "- [ ] once\r")
    }

    @Test func stampGoesAfterOtherTokens() {
        let line = "- [ ] x >2026-07-20 !p1 #t @a ?discuss"
        #expect(complete(line) == line.replacingOccurrences(of: "- [ ]", with: "- [x]") + " ✅\(day)")
    }

    @Test func nestedAndNumberedPrefixes() {
        #expect(complete("  - [ ] sub") == "  - [x] sub ✅\(day)")
        #expect(complete("1. [ ] n") == "1. [x] n ✅\(day)")
        #expect(complete("\t* [ ] tabbed") == "\t* [x] tabbed ✅\(day)")
    }

    @Test func onlyFirstCheckboxOnALineFlips() {
        #expect(complete("- [ ] first [ ] second") == "- [x] first [ ] second ✅\(day)")
    }

    @Test func recurringStaysOpenNoStamp() {
        let completed = complete("- [ ] water plants >2026-07-10 &every 3 days")
        #expect(completed == "- [ ] water plants >2026-07-13 &every 3 days")
        #expect(completed?.contains("✅") == false)
    }

    @Test func recurringStripsStaleStamp() {
        #expect(
            complete("- [ ] w >2026-07-10 &every 3 days ✅2026-07-01")
                == "- [ ] w >2026-07-13 &every 3 days"
        )
    }

    @Test func recurringReopensCheckedLine() {
        #expect(
            complete("- [x] w >2026-07-10 &every 3 days ✅2026-07-01")
                == "- [ ] w >2026-07-13 &every 3 days"
        )
    }

    @Test func noCheckboxReturnsNil() {
        #expect(complete("- plain") == nil)
        #expect(complete("") == nil)
    }

    @Test func isoDayUsesCalendarTimeZone() throws {
        // 2026-07-11 23:30 UTC is already the 12th in Auckland (UTC+12).
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 11
        components.hour = 23; components.minute = 30
        components.timeZone = TimeZone(identifier: "UTC")
        let instant = try #require(Calendar(identifier: .gregorian).date(from: components))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))

        #expect(RecurrenceEngine.isoDay(instant, calendar: utc) == "2026-07-11")
        #expect(RecurrenceEngine.isoDay(instant, calendar: auckland) == "2026-07-12")
        #expect(
            RecurrenceEngine.completeTaskLine("- [ ] x", today: instant, calendar: auckland)
                == "- [x] x ✅2026-07-12"
        )
    }

    // MARK: - Editor splice agrees with the line primitive

    @Test func spliceEqualsLinePlusNewline() throws {
        let lines = [
            "- [ ] once", "- [x] once ✅2026-07-10", "- [ ] w >2026-07-10 &every 3 days",
            "  - [ ] sub #t", "1. [ ] n", "- [ ] crlf\r",
        ]
        for line in lines {
            let text = line + "\n"
            let box = (text as NSString).range(of: "[")
            let range = NSRange(location: box.location, length: 3)
            let viaSplice = RecurrenceEngine.completeTask(
                in: text, tokenRange: range, today: today, calendar: calendar
            )
            let viaLine = try #require(complete(line)).appending("\n")
            #expect(viaSplice == viaLine, "editor and line paths must agree for: \(line)")
        }
    }
}

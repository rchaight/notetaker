@testable import CalendarKit
import Foundation
import Testing

private let chicago = TimeZone(identifier: "America/Chicago")!
private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = chicago
    return c
}

private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min, second: s))!
}

private func ev(
    _ id: String, _ title: String, _ start: Date, _ end: Date, allDay: Bool = false
) -> CalendarEvent {
    CalendarEvent(
        id: id, title: title, start: start, end: end, allDay: allDay,
        calendarId: "c1", calendarTitle: "Work", calendarColorHex: "#112233",
        location: "Room 4", status: .confirmed, organizer: "Ann", attendees: ["Bob", "Cy"]
    )
}

private func snapshot() -> CalendarSnapshot {
    CalendarSnapshot(
        generatedAt: d(2026, 10, 29, 8),
        rangeStart: d(2026, 10, 29), rangeEnd: d(2026, 11, 5),
        timeZone: chicago.identifier,
        calendars: [CalendarInfo(id: "c1", title: "Work", account: "iCloud", colorHex: "#112233")],
        events: [ev("a@1", "Zed", d(2026, 10, 29, 10), d(2026, 10, 29, 11)),
                 ev("b@2", "Alpha", d(2026, 10, 29, 9), d(2026, 10, 29, 9, 45))]
    )
}

struct CalendarKitTests {
    @Test func codecRoundTripAndStable() throws {
        let s = snapshot()
        let a = try SnapshotCodec.encode(s)
        let b = try SnapshotCodec.encode(s)
        #expect(a == b)
        let back = try SnapshotCodec.decode(a)
        #expect(back == s)
        #expect(back.events.first?.title == "Alpha")
    }

    @Test func unsupportedSchemaThrows() {
        let json = Data(#"{"schemaVersion": 99}"#.utf8)
        #expect(throws: SnapshotError.unsupportedSchema(found: 99)) {
            try SnapshotCodec.decode(json)
        }
    }

    @Test func noPrivateKeysInJSON() throws {
        let text = try String(decoding: SnapshotCodec.encode(snapshot()), as: UTF8.self)
        for key in ["notes", "url", "email"] {
            #expect(!text.contains("\"\(key)\""))
        }
    }

    @Test func rangeBounds() {
        let day = AgendaRange.day(d(2026, 3, 8, 15)).bounds(calendar: cal)
        #expect(day.end.timeIntervalSince(day.start) == 23 * 3600)
        let week = AgendaBuilder.days(events: [], range: .week(from: d(2026, 10, 27)), calendar: cal)
        #expect(week.count == 7)
        let custom = AgendaBuilder.days(
            events: [], range: .custom(from: d(2026, 10, 27, 5), to: d(2026, 10, 29, 20)), calendar: cal
        )
        #expect(custom.map(\.day) == ["2026-10-27", "2026-10-28", "2026-10-29"])
    }

    @Test func overlapRules() {
        let crossing = ev("x@1", "Late", d(2026, 10, 27, 23, 30), d(2026, 10, 28, 0, 30))
        let multi = ev("y@1", "Trip", d(2026, 10, 27), d(2026, 10, 29, 23, 59, 59), allDay: true)
        let days = AgendaBuilder.days(
            events: [crossing, multi], range: .week(from: d(2026, 10, 27)), calendar: cal
        )
        let on = { (id: String) in days.filter { $0.events.contains { $0.id == id } }.map(\.day) }
        #expect(on("x@1") == ["2026-10-27", "2026-10-28"])
        #expect(on("y@1") == ["2026-10-27", "2026-10-28", "2026-10-29"])
    }

    @Test func orderingWithinDay() {
        let events = [
            ev("1@1", "B timed", d(2026, 10, 28, 9), d(2026, 10, 28, 10)),
            ev("2@1", "A timed", d(2026, 10, 28, 9), d(2026, 10, 28, 10)),
            ev("3@1", "Early", d(2026, 10, 28, 8), d(2026, 10, 28, 8, 30)),
            ev("4@1", "Zed all", d(2026, 10, 28), d(2026, 10, 28, 23, 59, 59), allDay: true),
            ev("5@1", "Abe all", d(2026, 10, 28), d(2026, 10, 28, 23, 59, 59), allDay: true),
        ]
        let day = AgendaBuilder.days(events: events, range: .day(d(2026, 10, 28)), calendar: cal)[0]
        #expect(day.events.map(\.title) == ["Abe all", "Zed all", "Early", "A timed", "B timed"])
    }

    @Test func emptyDaysPresent() {
        let e = ev("1@1", "One", d(2026, 10, 29, 9), d(2026, 10, 29, 10))
        let days = AgendaBuilder.days(events: [e], range: .week(from: d(2026, 10, 27)), calendar: cal)
        #expect(days.count == 7)
        #expect(days.filter(\.events.isEmpty).count == 6)
    }

    @Test func overlappingBoundaries() {
        let start = d(2026, 10, 29, 9)
        let ends = ev("e@1", "Ends", d(2026, 10, 29, 8), start)
        let begins = ev("b@1", "Begins", start, d(2026, 10, 29, 10))
        let got = AgendaBuilder.events([ends, begins], overlapping: start, d(2026, 10, 29, 12))
        #expect(got.map(\.id) == ["b@1"])
    }

    @Test func recurringOccurrencesDistinct() {
        let a = ev("rec@100", "Standup", d(2026, 10, 27, 9), d(2026, 10, 27, 9, 15))
        let b = ev("rec@200", "Standup", d(2026, 10, 28, 9), d(2026, 10, 28, 9, 15))
        #expect(a.id != b.id)
        let days = AgendaBuilder.days(events: [a, b], range: .week(from: d(2026, 10, 27)), calendar: cal)
        #expect(days.flatMap(\.events).count == 2)
    }
}

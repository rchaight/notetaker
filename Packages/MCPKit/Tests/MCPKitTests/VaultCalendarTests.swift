import CalendarKit
import Foundation
import MCP
@testable import MCPKit
import Testing

struct VaultCalendarTests {
    static let zone = TimeZone(identifier: "America/Chicago")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// Wed 2026-10-29 12:00 Chicago.
    static var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
    }

    static func at(_ day: Int, _ hour: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    static func event(
        _ id: String, _ title: String, day: Int, hour: Int, calendar: String = "Work",
        location: String? = nil, organizer: String? = nil, attendees: [String] = []
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, title: title, start: at(day, hour), end: at(day, hour + 1), allDay: false,
            calendarId: calendar, calendarTitle: calendar, calendarColorHex: "#112233",
            location: location, status: .confirmed, organizer: organizer, attendees: attendees
        )
    }

    static func snapshot(
        generatedAt: Date = now.addingTimeInterval(-12 * 60), events: [CalendarEvent]? = nil
    ) -> CalendarSnapshot {
        CalendarSnapshot(
            generatedAt: generatedAt,
            rangeStart: at(28, 0), rangeEnd: at(26, 0, month: 11),
            timeZone: zone.identifier,
            calendars: [
                CalendarInfo(id: "Work", title: "Work", account: "iCloud", colorHex: "#112233"),
                CalendarInfo(id: "Home", title: "Home", account: "Google", colorHex: nil),
            ],
            events: events ?? [
                event("a", "Standup", day: 29, hour: 9),
                event(
                    "b", "1:1 Robert & Amber", day: 29, hour: 10, location: "Teams",
                    organizer: "Amber Smallwood", attendees: ["Robert Haight", "Amber Smallwood"]
                ),
                event("c", "Dentist", day: 30, hour: 8, calendar: "Home"),
                event("d", "Review", day: 31, hour: 14),
            ]
        )
    }

    func service(_ snapshot: CalendarSnapshot?, garbage: Bool = false) throws -> (VaultService, VaultFixture) {
        let fixture = try VaultFixture()
        if let snapshot {
            try SnapshotCodec.encode(snapshot).write(to: URL(fileURLWithPath: fixture.calendarSnapshotPath))
        } else if garbage {
            try Data("not json".utf8).write(to: URL(fileURLWithPath: fixture.calendarSnapshotPath))
        }
        return (fixture.service(withIndex: false), fixture)
    }

    func agenda(
        _ service: VaultService, _ query: VaultService.CalendarAgendaQuery, now: Date = VaultCalendarTests.now
    ) throws -> Value {
        try service.calendarAgenda(query, now: now, calendar: Self.calendar)
    }

    func titles(_ value: Value, day: Int) -> [String] {
        value["days"]?.arrayValue?[day]["events"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
    }

    @Test func todayTomorrowAndWeek() throws {
        let (svc, fixture) = try service(Self.snapshot())
        defer { fixture.cleanUp() }

        let today = try agenda(svc, .init())
        #expect(today["days"]?.arrayValue?.count == 1)
        #expect(titles(today, day: 0) == ["Standup", "1:1 Robert & Amber"])
        #expect(today["days"]?.arrayValue?[0]["is_today"]?.boolValue == true)
        #expect(today["days"]?.arrayValue?[0]["weekday"]?.stringValue == "Thursday")

        let tomorrow = try agenda(svc, .init(range: "tomorrow"))
        #expect(titles(tomorrow, day: 0) == ["Dentist"])

        let week = try agenda(svc, .init(range: "week"))
        #expect(week["days"]?.arrayValue?.count == 7)
        #expect(week["range"]?["from"]?.stringValue == "2026-10-29")
        #expect(week["range"]?["to"]?.stringValue == "2026-11-04")
        #expect(titles(week, day: 3).isEmpty)
        #expect(titles(week, day: 2) == ["Review"])
    }

    @Test func customRangeIsInclusiveAndValidated() async throws {
        let (svc, fixture) = try service(Self.snapshot())
        defer { fixture.cleanUp() }
        let custom = try agenda(svc, .init(range: "custom", from: "2026-10-30", to: "2026-10-31"))
        #expect(custom["days"]?.arrayValue?.count == 2)
        #expect(titles(custom, day: 0) == ["Dentist"])
        #expect(titles(custom, day: 1) == ["Review"])

        let missing = await NotetakerMCPServer.call(
            name: "calendar_agenda",
            arguments: ["range": .string("custom"), "from": .string("2026-10-30")],
            service: svc
        )
        #expect(missing.isError == true)
        guard case let .text(text, _, _) = missing.content.first else {
            Issue.record("expected text")
            return
        }
        #expect(text.contains("to is required"))
    }

    @Test func calendarFilterIsCaseInsensitive() throws {
        let (svc, fixture) = try service(Self.snapshot())
        defer { fixture.cleanUp() }
        let week = try agenda(svc, .init(range: "week", calendar: "hOmE"))
        let all = (0 ..< 7).flatMap { titles(week, day: $0) }
        #expect(all == ["Dentist"])
    }

    @Test func staleAndAge() throws {
        let fresh = try service(Self.snapshot(generatedAt: Self.now.addingTimeInterval(-5 * 60)))
        defer { fresh.1.cleanUp() }
        let a = try agenda(fresh.0, .init())
        #expect(a["stale"]?.boolValue == false)
        #expect(a["snapshot_age_minutes"]?.intValue == 5)

        let old = try service(Self.snapshot(generatedAt: Self.now.addingTimeInterval(-7 * 3600)))
        defer { old.1.cleanUp() }
        let b = try agenda(old.0, .init())
        #expect(b["stale"]?.boolValue == true)
        #expect(b["snapshot_age_minutes"]?.intValue == 420)
    }

    @Test func coverageNote() throws {
        let (svc, fixture) = try service(Self.snapshot())
        defer { fixture.cleanUp() }
        let beyond = try agenda(svc, .init(range: "custom", from: "2026-11-25", to: "2026-11-28"))
        let note = beyond["coverage_note"]?.stringValue
        #expect(note?.contains("2026-10-28") == true)
        #expect(note?.contains("shown empty") == true)
        let inside = try agenda(svc, .init(range: "week"))
        if case .null? = inside["coverage_note"] {} else {
            Issue.record("expected null coverage_note")
        }
    }

    @Test func missingAndGarbageFilesAreAnswersNotErrors() async throws {
        let (svc, fixture) = try service(nil)
        defer { fixture.cleanUp() }
        let missing = await NotetakerMCPServer.call(name: "calendar_agenda", arguments: [:], service: svc)
        #expect(missing.isError == false)
        #expect(missing.structuredContent?["available"]?.boolValue == false)
        #expect(missing.structuredContent?["reason"]?.stringValue?.contains("Share upcoming events") == true)

        let (bad, badFixture) = try service(nil, garbage: true)
        defer { badFixture.cleanUp() }
        let garbage = await NotetakerMCPServer.call(name: "calendar_list", arguments: [:], service: bad)
        #expect(garbage.isError == false)
        #expect(garbage.structuredContent?["available"]?.boolValue == false)
        #expect(garbage.structuredContent?["reason"]?.stringValue?.contains("unreadable") == true)
    }

    @Test func eventKeysArePinnedToThePrivacyContract() throws {
        let (svc, fixture) = try service(Self.snapshot())
        defer { fixture.cleanUp() }
        let today = try agenda(svc, .init())
        let event = try #require(today["days"]?.arrayValue?[0]["events"]?.arrayValue?[1].objectValue)
        #expect(Set(event.keys) == [
            "id", "title", "start", "end", "all_day", "calendar", "location", "status",
            "organizer", "attendees",
        ])
        #expect(event["start"]?.stringValue == "2026-10-29T10:00:00-05:00")
        #expect(event["attendees"]?.arrayValue?.count == 2)
    }

    @Test func calendarListReturnsCalendarsWithColor() throws {
        let (svc, fixture) = try service(Self.snapshot())
        defer { fixture.cleanUp() }
        let list = svc.calendarList(now: Self.now)
        let calendars = try #require(list["calendars"]?.arrayValue)
        #expect(calendars.count == 2)
        #expect(calendars[0]["color"]?.stringValue == "#112233")
        #expect(calendars[0]["account"]?.stringValue == "iCloud")
        #expect(list["stale"]?.boolValue == false)
    }
}

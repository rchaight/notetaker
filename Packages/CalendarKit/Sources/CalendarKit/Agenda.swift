import Foundation

public enum AgendaRange: Equatable, Sendable {
    case day(Date)
    case week(from: Date)
    /// Inclusive days.
    case custom(from: Date, to: Date)

    /// Half-open [start, end), both at startOfDay.
    public func bounds(calendar: Calendar) -> (start: Date, end: Date) {
        func add(_ days: Int, to date: Date) -> Date {
            calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86400)
        }
        switch self {
        case let .day(date):
            let s = calendar.startOfDay(for: date)
            return (s, add(1, to: s))
        case let .week(from):
            let s = calendar.startOfDay(for: from)
            return (s, add(7, to: s))
        case let .custom(from, to):
            let s = calendar.startOfDay(for: from)
            let e = add(1, to: calendar.startOfDay(for: to))
            return (s, max(e, add(1, to: s)))
        }
    }
}

public struct AgendaDay: Identifiable, Equatable, Sendable {
    public var id: String {
        day
    }

    public let day: String
    public let date: Date
    public let events: [CalendarEvent]

    public init(day: String, date: Date, events: [CalendarEvent]) {
        self.day = day
        self.date = date
        self.events = events
    }
}

public enum AgendaBuilder {
    /// Effective exclusive end of an event. All-day events that EventKit ends
    /// at 23:59:59 are clamped to the start of the following day; zero-length
    /// events occupy their start instant.
    private static func effectiveEnd(_ e: CalendarEvent, calendar: Calendar) -> Date {
        if e.allDay {
            let endDay = calendar.startOfDay(for: e.end)
            // end exactly at midnight is already exclusive; otherwise round up.
            let exclusive = e.end > endDay
                ? (calendar.date(byAdding: .day, value: 1, to: endDay) ?? e.end)
                : endDay
            return max(exclusive, e.start)
        }
        return e.end
    }

    private static func overlaps(
        _ e: CalendarEvent, _ start: Date, _ end: Date, calendar: Calendar
    ) -> Bool {
        let eEnd = effectiveEnd(e, calendar: calendar)
        if eEnd <= e.start { // zero-length: instant
            return e.start >= start && e.start < end
        }
        return e.start < end && eEnd > start
    }

    public static func days(
        events: [CalendarEvent], range: AgendaRange, calendar: Calendar
    ) -> [AgendaDay] {
        let (start, end) = range.bounds(calendar: calendar)
        var result: [AgendaDay] = []
        var cursor = start
        while cursor < end {
            let next = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end
            let todays = events
                .filter { overlaps($0, cursor, next, calendar: calendar) }
                .sorted { a, b in
                    if a.allDay != b.allDay {
                        return a.allDay
                    }
                    if a.allDay {
                        return (a.title, a.id) < (b.title, b.id)
                    }
                    return (a.start, a.title, a.id) < (b.start, b.title, b.id)
                }
            result.append(AgendaDay(
                day: DayKey.string(for: cursor, calendar: calendar),
                date: cursor, events: todays
            ))
            cursor = next
        }
        return result
    }

    /// Events overlapping [start, end). Overlap uses the same all-day clamp as `days`.
    public static func events(
        _ events: [CalendarEvent], overlapping start: Date, _ end: Date
    ) -> [CalendarEvent] {
        events.filter { overlaps($0, start, end, calendar: .current) }
    }
}

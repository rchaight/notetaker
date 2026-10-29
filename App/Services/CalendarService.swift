import CalendarKit
import CoreGraphics
import EventKit
import Foundation

/// EventKit bridge: one API surfaces Apple, Google, and Outlook/Exchange
/// calendars — any account added to the system Calendar app. Nothing
/// leaves the device; no OAuth or tokens to manage.
enum CalendarService {
    private nonisolated(unsafe) static let store = EKEventStore()

    enum Access: String {
        case notRequested, granted, denied
    }

    static func accessState() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notRequested
        default: .denied
        }
    }

    /// Triggers the system permission dialog when not yet determined.
    static func requestAccess() async -> Bool {
        await (try? store.requestFullAccessToEvents()) ?? false
    }

    struct Meeting: Equatable, Sendable {
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
    }

    /// The day's events across all included calendars, sorted by start.
    static func meetings(
        on day: Date, excludedCalendarIds: Set<String> = [], calendar: Calendar = .current
    ) -> [Meeting] {
        guard accessState() == .granted else { return [] }
        let startOfDay = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        let calendars = store.calendars(for: .event)
            .filter { !excludedCalendarIds.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(
            withStart: startOfDay, end: endOfDay, calendars: calendars
        )
        return store.events(matching: predicate)
            .map {
                Meeting(
                    title: $0.title ?? "Untitled event",
                    start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// All event calendars, for the Settings include/exclude list.
    static func availableCalendars() -> [(id: String, title: String, account: String)] {
        guard accessState() == .granted else { return [] }
        return store.calendars(for: .event).map {
            ($0.calendarIdentifier, $0.title, $0.source.title)
        }
    }

    /// The meetings block for a daily note: each event a TOP-LEVEL heading
    /// followed by three returns (user-specified format — room to take
    /// notes under each meeting).
    static func meetingsMarkdown(
        on day: Date, excludedCalendarIds: Set<String> = []
    ) -> String {
        let events = meetings(on: day, excludedCalendarIds: excludedCalendarIds)
        guard !events.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return events.map { meeting in
            let time = meeting.allDay
                ? "All day"
                : "\(formatter.string(from: meeting.start))–\(formatter.string(from: meeting.end))"
            return "# \(time) — \(meeting.title)\n\n\n"
        }.joined()
    }

    // MARK: - CalendarKit mapping

    private static func includedEKCalendars(_ excluded: Set<String>) -> [EKCalendar] {
        guard accessState() == .granted else { return [] }
        return store.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              c.count >= 3
        else { return nil }
        func byte(_ v: CGFloat) -> Int {
            Int((min(max(v, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(c[0]), byte(c[1]), byte(c[2]))
    }

    /// Included calendars (every event calendar minus the excluded set).
    static func includedCalendars(
        excludedCalendarIds: Set<String> = excludedCalendarIds()
    ) -> [CalendarInfo] {
        includedEKCalendars(excludedCalendarIds).map {
            CalendarInfo(
                id: $0.calendarIdentifier, title: $0.title,
                account: $0.source.title, colorHex: hex($0.cgColor)
            )
        }
    }

    /// Events overlapping [start, end) across the included calendars, mapped to
    /// CalendarKit's model. Empty when access is not granted.
    static func events(
        from start: Date, to end: Date,
        excludedCalendarIds: Set<String> = excludedCalendarIds()
    ) -> [CalendarEvent] {
        let calendars = includedEKCalendars(excludedCalendarIds)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map { e in
            let status: CalendarEvent.Status = switch e.status {
            case .confirmed: .confirmed
            case .tentative: .tentative
            case .canceled: .canceled
            default: .none
            }
            let location = e.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CalendarEvent(
                id: "\(e.eventIdentifier ?? UUID().uuidString)@\(Int(e.startDate.timeIntervalSince1970))",
                title: e.title ?? "Untitled event",
                start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                calendarId: e.calendar.calendarIdentifier,
                calendarTitle: e.calendar.title,
                calendarColorHex: hex(e.calendar.cgColor),
                location: (location?.isEmpty ?? true) ? nil : location,
                status: status,
                // Participants without a display name report their email as the name; never share those.
                organizer: e.organizer?.name.flatMap { $0.contains("@") ? nil : $0 },
                attendees: e.attendees?.compactMap(\.name).filter { !$0.contains("@") } ?? []
            )
        }
        .sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
    }

    /// A snapshot for [startOfDay(today - daysBack), startOfDay(today + daysAhead)).
    static func snapshot(
        daysBack: Int, daysAhead: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> CalendarSnapshot {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: daysAhead, to: today) ?? today
        let excluded = excludedCalendarIds()
        let all = events(from: start, to: end, excludedCalendarIds: excluded)
        return CalendarSnapshot(
            generatedAt: now, rangeStart: start, rangeEnd: end,
            timeZone: calendar.timeZone.identifier,
            calendars: includedCalendars(excludedCalendarIds: excluded),
            events: AgendaBuilder.events(all, overlapping: start, end)
        )
    }

    static func excludedCalendarIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedCalendarIds") ?? [])
    }

    static func setExcluded(_ id: String, excluded: Bool) {
        var current = excludedCalendarIds()
        if excluded {
            current.insert(id)
        } else {
            current.remove(id)
        }
        UserDefaults.standard.set(Array(current), forKey: "excludedCalendarIds")
    }
}

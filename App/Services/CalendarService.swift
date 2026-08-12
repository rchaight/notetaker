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

import Foundation

/// One event calendar (included calendars only appear in snapshots).
public struct CalendarInfo: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public let account: String
    public let colorHex: String?

    public init(id: String, title: String, account: String, colorHex: String?) {
        self.id = id
        self.title = title
        self.account = account
        self.colorHex = colorHex
    }
}

/// A calendar event. Deliberately absent: notes/description, URL, attendee emails.
public struct CalendarEvent: Identifiable, Equatable, Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable {
        case none, confirmed, tentative, canceled
    }

    /// "<eventIdentifier>@<start unix seconds>" — eventIdentifier is shared by
    /// every occurrence of a recurring event, so the start disambiguates.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let calendarId: String
    public let calendarTitle: String
    public let calendarColorHex: String?
    public let location: String?
    public let status: Status
    public let organizer: String?
    public let attendees: [String]

    public init(
        id: String, title: String, start: Date, end: Date, allDay: Bool,
        calendarId: String, calendarTitle: String, calendarColorHex: String? = nil,
        location: String? = nil, status: Status = .none,
        organizer: String? = nil, attendees: [String] = []
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.location = location
        self.status = status
        self.organizer = organizer
        self.attendees = attendees
    }
}

public struct CalendarSnapshot: Equatable, Sendable, Codable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let rangeStart: Date
    /// Exclusive.
    public let rangeEnd: Date
    public let timeZone: String
    public let calendars: [CalendarInfo]
    /// Sorted by start, then title.
    public let events: [CalendarEvent]

    public init(
        generatedAt: Date, rangeStart: Date, rangeEnd: Date, timeZone: String,
        calendars: [CalendarInfo], events: [CalendarEvent],
        schemaVersion: Int = CalendarSnapshot.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.timeZone = timeZone
        self.calendars = calendars
        self.events = events.sorted {
            ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id)
        }
    }
}

public enum DayKey {
    private static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// "yyyy-MM-dd" with en_US_POSIX, in `calendar.timeZone`.
    public static func string(for date: Date, calendar: Calendar) -> String {
        formatter(calendar).string(from: date)
    }

    public static func date(from key: String, calendar: Calendar) -> Date? {
        formatter(calendar).date(from: key)
    }
}

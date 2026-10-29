import CalendarKit
import Foundation
import MCP

/// Calendar tools. The data is a snapshot the app writes when the user opts
/// in (Settings › Calendar); the server never touches EventKit. Read fresh
/// on every call — the app may rewrite the file at any moment.
extension VaultService {
    struct CalendarAgendaQuery: Sendable {
        var range: String?
        var from: String?
        var to: String?
        var calendar: String?
    }

    static let staleAfterSeconds: TimeInterval = 6 * 3600

    static let unavailableSharingOff = """
    Calendar sharing is off. Turn on Settings › Calendar › "Share upcoming events with the MCP server" in Notetaker.
    """

    private enum SnapshotLoad {
        case ok(CalendarSnapshot)
        case unavailable(String)
    }

    private func loadSnapshot() -> SnapshotLoad {
        let url = URL(fileURLWithPath: location.calendarSnapshotPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable(Self.unavailableSharingOff)
        }
        do {
            return try .ok(SnapshotCodec.decode(Data(contentsOf: url)))
        } catch {
            return .unavailable("snapshot unreadable (\(error)) — open Notetaker to regenerate it")
        }
    }

    private func unavailable(_ reason: String) -> Value {
        .object(["available": .bool(false), "reason": .string(reason), "source": .string("snapshot")])
    }

    func calendarAgenda(
        _ query: CalendarAgendaQuery, now: Date = Date(), calendar: Calendar = .current
    ) throws -> Value {
        let snapshot: CalendarSnapshot
        switch loadSnapshot() {
        case let .unavailable(reason): return unavailable(reason)
        case let .ok(loaded): snapshot = loaded
        }

        var cal = calendar
        if let zone = TimeZone(identifier: snapshot.timeZone) {
            cal.timeZone = zone
        }

        let range: AgendaRange
        switch query.range ?? "today" {
        case "today":
            range = .day(now)
        case "tomorrow":
            range = .day(cal.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400))
        case "week":
            range = .week(from: now)
        case "custom":
            guard let fromKey = query.from, !fromKey.isEmpty else {
                throw MCPError.invalidParams("from is required when range is custom")
            }
            guard let toKey = query.to, !toKey.isEmpty else {
                throw MCPError.invalidParams("to is required when range is custom")
            }
            guard let from = DayKey.date(from: fromKey, calendar: cal) else {
                throw MCPError.invalidParams("from must be yyyy-mm-dd")
            }
            guard let to = DayKey.date(from: toKey, calendar: cal) else {
                throw MCPError.invalidParams("to must be yyyy-mm-dd")
            }
            range = .custom(from: from, to: to)
        default:
            throw MCPError.invalidParams("range must be today, tomorrow, week or custom")
        }

        var events = snapshot.events
        if let filter = query.calendar?.trimmingCharacters(in: .whitespaces), !filter.isEmpty {
            events = events.filter { $0.calendarTitle.caseInsensitiveCompare(filter) == .orderedSame }
        }

        let days = AgendaBuilder.days(events: events, range: range, calendar: cal)
        let bounds = range.bounds(calendar: cal)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = cal.timeZone
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime]
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.timeZone = cal.timeZone
        weekday.dateFormat = "EEEE"
        let todayKey = DayKey.string(for: now, calendar: cal)

        var coverageNote: Value = .null
        if bounds.start < snapshot.rangeStart || bounds.end > snapshot.rangeEnd {
            let last = snapshot.rangeEnd.addingTimeInterval(-1)
            coverageNote = .string(
                "Snapshot covers \(DayKey.string(for: snapshot.rangeStart, calendar: cal)) … "
                    + "\(DayKey.string(for: last, calendar: cal)); days outside it are shown empty."
            )
        }

        let age = now.timeIntervalSince(snapshot.generatedAt)
        return .object([
            "available": .bool(true),
            "source": .string("snapshot"),
            "generated_at": .string(utc.string(from: snapshot.generatedAt)),
            "snapshot_age_minutes": .int(Int((age / 60).rounded(.down))),
            "stale": .bool(age > Self.staleAfterSeconds),
            "time_zone": .string(snapshot.timeZone),
            "range": .object([
                "from": .string(days.first?.day ?? DayKey.string(for: bounds.start, calendar: cal)),
                "to": .string(days.last?.day ?? DayKey.string(for: bounds.start, calendar: cal)),
            ]),
            "coverage_note": coverageNote,
            "days": .array(days.map { day in
                .object([
                    "day": .string(day.day),
                    "weekday": .string(weekday.string(from: day.date)),
                    "is_today": .bool(day.day == todayKey),
                    "events": .array(day.events.map { eventValue($0, formatter) }),
                ])
            }),
        ])
    }

    func calendarList(now: Date = Date()) -> Value {
        let snapshot: CalendarSnapshot
        switch loadSnapshot() {
        case let .unavailable(reason): return unavailable(reason)
        case let .ok(loaded): snapshot = loaded
        }
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime]
        return .object([
            "available": .bool(true),
            "generated_at": .string(utc.string(from: snapshot.generatedAt)),
            "stale": .bool(now.timeIntervalSince(snapshot.generatedAt) > Self.staleAfterSeconds),
            "calendars": .array(snapshot.calendars.map {
                .object([
                    "id": .string($0.id),
                    "title": .string($0.title),
                    "account": .string($0.account),
                    "color": $0.colorHex.map { .string($0) } ?? .null,
                ])
            }),
        ])
    }

    private func eventValue(_ event: CalendarEvent, _ formatter: ISO8601DateFormatter) -> Value {
        .object([
            "id": .string(event.id),
            "title": .string(event.title),
            "start": .string(formatter.string(from: event.start)),
            "end": .string(formatter.string(from: event.end)),
            "all_day": .bool(event.allDay),
            "calendar": .string(event.calendarTitle),
            "location": event.location.map { .string($0) } ?? .null,
            "status": .string(event.status.rawValue),
            "organizer": event.organizer.map { .string($0) } ?? .null,
            "attendees": .array(event.attendees.map { .string($0) }),
        ])
    }
}

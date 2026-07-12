import Foundation

/// Where a task lands in the master To-Do views. Every open task is in
/// exactly one bucket; overdue tasks stay overdue until completed,
/// rescheduled, or dismissed — they never silently disappear.
public enum SmartBucket: String, CaseIterable, Sendable {
    case overdue
    case today
    case upcoming
    /// Undated tasks.
    case inbox
}

public enum SmartBuckets {
    /// Buckets a task by its ISO yyyy-MM-dd dates. Unparseable or missing
    /// dates land in the inbox rather than being dropped. An unstarted task
    /// (future ~start) stays out of Today — Things-style — unless its due
    /// date already passed (overdue always wins).
    public static func bucket(
        dueDate: String?,
        startDate: String? = nil,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> SmartBucket {
        let startOfToday = calendar.startOfDay(for: today)

        if let dueDate, let due = parseISO(dueDate, calendar: calendar),
           calendar.startOfDay(for: due) < startOfToday {
            return .overdue
        }
        if let startDate, let start = parseISO(startDate, calendar: calendar),
           calendar.startOfDay(for: start) > startOfToday {
            return .upcoming
        }
        guard let dueDate, let due = parseISO(dueDate, calendar: calendar) else { return .inbox }
        if calendar.startOfDay(for: due) == startOfToday {
            return .today
        }
        return .upcoming
    }

    /// ISO day string for "N days from today" — shared by tests and views.
    public static func isoDay(
        offsetFromToday offset: Int,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
        return isoFormatter(calendar).string(from: date)
    }

    private static func parseISO(_ string: String, calendar: Calendar) -> Date? {
        isoFormatter(calendar).date(from: string)
    }

    private static func isoFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

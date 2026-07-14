import Foundation

/// Local-only completion stats (opt-in UI): "N done today · M-day streak".
/// Computed from ✅completion days; no server, no karma economy.
public enum Streaks {
    public struct Stats: Equatable, Sendable {
        public let doneToday: Int
        public let streakDays: Int
    }

    /// - Parameter completedDays: one entry per completed task ("yyyy-MM-dd",
    ///   duplicates expected). A streak is consecutive calendar days with at
    ///   least one completion, counted back from today — or from yesterday,
    ///   so an unfinished today doesn't zero an ongoing streak.
    public static func compute(
        completedDays: [String], today: Date = Date(), calendar: Calendar = .current
    ) -> Stats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let todayISO = formatter.string(from: today)
        let days = Set(completedDays)
        let doneToday = completedDays.count(where: { $0 == todayISO })

        var cursor = today
        if !days.contains(todayISO) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(formatter.string(from: yesterday))
            else { return Stats(doneToday: doneToday, streakDays: 0) }
            cursor = yesterday
        }
        var streak = 0
        while days.contains(formatter.string(from: cursor)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return Stats(doneToday: doneToday, streakDays: streak)
    }
}

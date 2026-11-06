import Foundation

/// A task's repetition rule.
/// `&every …` = fixed schedule anchored to the due date;
/// `&after …` = completion-based ("N days after I actually did it").
public struct Recurrence: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case fixed
        case afterCompletion
    }

    public enum Unit: String, Sendable {
        case day, week, month, year
    }

    public let kind: Kind
    public let interval: Int
    /// nil when the rule is weekday-based ("&every friday").
    public let unit: Unit?
    /// Calendar weekday 1 (Sunday) … 7 (Saturday) for weekday rules.
    public let weekday: Int?
    /// The exact token as written, preserved for re-serialization/indexing.
    public let rawToken: String

    public init(kind: Kind, interval: Int, unit: Unit?, weekday: Int?, rawToken: String) {
        self.kind = kind
        self.interval = interval
        self.unit = unit
        self.weekday = weekday
        self.rawToken = rawToken
    }
}

public enum RecurrenceParser {
    private static let regex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)&(every|after)\s+(?:([0-9]+)\s+)?(day|days|week|weeks|month|months|year|years|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
        options: [.caseInsensitive]
    )

    private static let weekdays = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    /// UTF-16 ranges of every `&every …` / `&after …` token in `text`,
    /// against the ORIGINAL string (`extract` mutates as it goes, so its
    /// match ranges can't be reused). Feeds `TaskTokenParser.tokenRanges`,
    /// which is the only caller — the recurrence pattern stays in this
    /// file so there is still exactly one of it.
    static func tokenRanges(in text: String) -> [NSRange] {
        guard let regex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    /// Extracts and removes the first recurrence token from `text`.
    public static func extract(from text: inout String) -> Recurrence? {
        guard let regex else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }

        let rawToken = ns.substring(with: match.range)
        let kindWord = ns.substring(with: match.range(at: 1)).lowercased()
        let count = match.range(at: 2).location == NSNotFound
            ? 1
            : Int(ns.substring(with: match.range(at: 2))) ?? 1
        let unitWord = ns.substring(with: match.range(at: 3)).lowercased()

        guard count >= 1 else { return nil } // "&every 0 days" must never parse
        let kind: Recurrence.Kind = kindWord == "after" ? .afterCompletion : .fixed
        let recurrence: Recurrence
        if let weekday = weekdays[unitWord] {
            recurrence = Recurrence(kind: kind, interval: count, unit: nil, weekday: weekday, rawToken: rawToken)
        } else {
            let unit: Recurrence.Unit? = switch unitWord {
            case "day", "days": .day
            case "week", "weeks": .week
            case "month", "months": .month
            case "year", "years": .year
            default: nil
            }
            guard let unit else { return nil }
            recurrence = Recurrence(kind: kind, interval: count, unit: unit, weekday: nil, rawToken: rawToken)
        }
        text = ns.replacingCharacters(in: match.range, with: "")
        return recurrence
    }
}

/// Regeneration math + the single line-level completion primitive every
/// surface calls. Completing a recurring line NEVER produces "[x] with no
/// next instance" — the date advances and the box stays open.
public enum RecurrenceEngine {
    /// The next due date after completing the task.
    public static func nextDueDate(
        recurrence: Recurrence,
        currentDue: String?,
        completedOn: Date,
        calendar: Calendar = .current
    ) -> String {
        let formatter = isoFormatter(calendar)
        let completionDay = calendar.startOfDay(for: completedOn)

        if let weekday = recurrence.weekday {
            // Next matching weekday strictly after the completion day.
            var candidate = calendar.date(byAdding: .day, value: 1, to: completionDay) ?? completionDay
            while calendar.component(.weekday, from: candidate) != weekday {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return formatter.string(from: candidate)
        }

        let unit: Calendar.Component = switch recurrence.unit ?? .day {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }

        switch recurrence.kind {
        case .afterCompletion:
            let next = calendar.date(byAdding: unit, value: recurrence.interval, to: completionDay) ?? completionDay
            return formatter.string(from: next)
        case .fixed:
            // Advance from the scheduled due date; catch up past-due series
            // so the next instance is always in the future. The loop is
            // hang-proof: it exits whenever a step fails to move forward.
            var base = currentDue.flatMap { formatter.date(from: $0) } ?? completionDay
            repeat {
                guard let advanced = calendar.date(
                    byAdding: unit, value: max(recurrence.interval, 1), to: base
                ), advanced > base else { break }
                base = advanced
            } while calendar.startOfDay(for: base) <= completionDay
            return formatter.string(from: base)
        }
    }

    /// Completes one task line — the ONE line-level primitive behind every
    /// check-off surface (editor, Reading mode, master list, Logbook).
    ///
    /// - Recurring: rewrite the `>date` to the next occurrence and keep the
    ///   box `[ ]`; a stale `✅day` stamp (contradictory on an open box) is
    ///   stripped.
    /// - Non-recurring, `[ ]` → `[x]`: append ` ✅<today>` (after any other
    ///   token, before trailing spaces/`\r`), replacing a stale stamp.
    /// - Non-recurring, `[x]`/`[X]` → `[ ]`: remove the `✅day` stamp.
    ///
    /// Returns nil when the line has no checkbox.
    public static func completeTaskLine(
        _ line: String,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        var probe = line
        guard let recurrence = RecurrenceParser.extract(from: &probe) else {
            guard let (flipped, nowChecked) = flipCheckbox(in: line) else { return nil }
            let unstamped = strippingCompletionStamp(flipped)
            return nowChecked
                ? appendingCompletionStamp(isoDay(today, calendar: calendar), to: unstamped)
                : unstamped
        }

        // Current >due on the line, if any.
        var working = line
        let currentDue = TaskTokenParser.parse(working, today: today, calendar: calendar).dueDate
        let next = nextDueDate(
            recurrence: recurrence, currentDue: currentDue,
            completedOn: today, calendar: calendar
        )

        // Replace the existing >token or append the next one.
        if let dueRange = firstDueTokenRange(in: working) {
            working = (working as NSString).replacingCharacters(in: dueRange, with: ">\(next)")
        } else {
            working += " >\(next)"
        }
        // Ensure the box is open — completing a recurring task resets it.
        if let (unchecked, nowChecked) = flipCheckbox(in: working), nowChecked == false {
            working = unchecked
        }
        return strippingCompletionStamp(working)
    }

    /// `yyyy-MM-dd` for `date` in `calendar`'s time zone — the one day
    /// formatter behind due-date advancement and the `✅` completion stamp,
    /// so callers never format dates themselves in the completion path.
    public static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        isoFormatter(calendar).string(from: date)
    }

    /// Editor-surface helper: completes the task line containing
    /// `tokenRange` and splices it back into the full text.
    public static func completeTask(
        in text: String,
        tokenRange: NSRange,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let ns = text as NSString
        guard NSMaxRange(tokenRange) <= ns.length else { return nil }
        let lineRange = ns.paragraphRange(for: tokenRange)
        // Strip exactly one UTF-16 "\n". `String.hasSuffix`/`removeLast` work
        // on Characters, where "\r\n" is ONE grapheme: a CRLF line would keep
        // its "\r\n" glued to the text and the ✅ stamp would land after the
        // newline. The line primitive owns a trailing "\r".
        let trailingNewline = lineRange.length > 0
            && ns.character(at: NSMaxRange(lineRange) - 1) == 0x0A
        let body = trailingNewline
            ? NSRange(location: lineRange.location, length: lineRange.length - 1)
            : lineRange
        let line = ns.substring(with: body)
        guard let completed = completeTaskLine(line, today: today, calendar: calendar) else { return nil }
        return ns.replacingCharacters(
            in: lineRange,
            with: completed + (trailingNewline ? "\n" : "")
        )
    }

    // MARK: - Helpers

    private static let dueTokenRegex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)>(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|[0-9]{4}-[0-9]{2}-[0-9]{2})\b"#,
        options: [.caseInsensitive]
    )

    private static func firstDueTokenRange(in text: String) -> NSRange? {
        guard let regex = dueTokenRegex else { return nil }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))?.range
    }

    private static func flipCheckbox(in line: String) -> (String, Bool)? {
        let ns = line as NSString
        let unchecked = ns.range(of: "[ ]")
        let checkedLower = ns.range(of: "[x]")
        let checkedUpper = ns.range(of: "[X]")
        let checked = checkedLower.location != NSNotFound ? checkedLower : checkedUpper

        if unchecked.location != NSNotFound,
           checked.location == NSNotFound || unchecked.location < checked.location {
            return (ns.replacingCharacters(in: unchecked, with: "[x]"), true)
        }
        if checked.location != NSNotFound {
            return (ns.replacingCharacters(in: checked, with: "[ ]"), false)
        }
        return nil
    }

    /// ` ✅yyyy-MM-dd` with one adjacent leading space (the Logbook token).
    private static let completionStampRegex = try? NSRegularExpression(
        pattern: " ?✅[0-9]{4}-[0-9]{2}-[0-9]{2}"
    )

    /// The line with every `✅day` stamp (and one adjacent space) removed.
    private static func strippingCompletionStamp(_ line: String) -> String {
        guard let regex = completionStampRegex else { return line }
        return regex.stringByReplacingMatches(
            in: line, range: NSRange(location: 0, length: (line as NSString).length),
            withTemplate: ""
        )
    }

    /// Appends ` ✅day`, keeping trailing spaces / `\r` byte-exact after it.
    private static func appendingCompletionStamp(_ day: String, to line: String) -> String {
        let trailing = String(line.reversed().prefix { $0 == " " || $0 == "\r" }.reversed())
        return String(line.dropLast(trailing.count)) + " ✅" + day + trailing
    }

    private static func isoFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

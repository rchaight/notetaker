import Foundation

/// Metadata parsed from a task's inline tokens.
public struct ParsedTaskMetadata: Equatable, Sendable {
    /// Task text with `>date` and `!priority` tokens removed (tags stay —
    /// they read as content).
    public let cleanText: String
    /// ISO yyyy-MM-dd.
    public let dueDate: String?
    /// 1 (highest) … 4, Todoist-style.
    public let priority: Int?
    /// #tag labels found in the text, without '#'.
    public let labels: [String]
    /// `&every …` / `&after …` repetition rule.
    public let recurrence: Recurrence?

    public init(
        cleanText: String,
        dueDate: String?,
        priority: Int?,
        labels: [String],
        recurrence: Recurrence? = nil
    ) {
        self.cleanText = cleanText
        self.dueDate = dueDate
        self.priority = priority
        self.labels = labels
        self.recurrence = recurrence
    }
}

/// The ONE parser for inline task tokens — every surface (editor, quick
/// add, master list) must use this so `- [ ] text >friday !p1 #tag` means
/// the same thing everywhere.
///
/// Tokens: `>today` `>tomorrow` `>monday`…`>sunday` `>2026-07-15` ·
/// `!p1`…`!p4` `!high` `!medium` `!low`.
public enum TaskTokenParser {
    public static func parse(
        _ text: String,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> ParsedTaskMetadata {
        var working = text
        let dueDate = extractDue(&working, today: today, calendar: calendar)
        let priority = extractPriority(&working)
        let recurrence = RecurrenceParser.extract(from: &working)
        let labels = tagTokens(in: working)
        let clean = working
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return ParsedTaskMetadata(
            cleanText: clean, dueDate: dueDate, priority: priority,
            labels: labels, recurrence: recurrence
        )
    }

    // MARK: - Dates

    private static let dueRegex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)>(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|[0-9]{4}-[0-9]{2}-[0-9]{2})\b"#,
        options: [.caseInsensitive]
    )

    private static func extractDue(_ text: inout String, today: Date, calendar: Calendar) -> String? {
        guard let regex = dueRegex else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let token = ns.substring(with: match.range(at: 1)).lowercased()
        text = ns.replacingCharacters(in: match.range, with: "")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        switch token {
        case "today":
            return formatter.string(from: today)
        case "tomorrow":
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            return formatter.string(from: tomorrow)
        case "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday":
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            guard let target = weekdays.firstIndex(of: token) else { return nil }
            let current = calendar.component(.weekday, from: today) - 1
            var delta = (target - current + 7) % 7
            if delta == 0 {
                delta = 7
            } // ">friday" on a Friday = next Friday
            let date = calendar.date(byAdding: .day, value: delta, to: today) ?? today
            return formatter.string(from: date)
        default:
            return token // already yyyy-MM-dd
        }
    }

    // MARK: - Priority

    private static let priorityRegex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)!(p[1-4]|high|medium|med|low)\b"#,
        options: [.caseInsensitive]
    )

    private static func extractPriority(_ text: inout String) -> Int? {
        guard let regex = priorityRegex else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let token = ns.substring(with: match.range(at: 1)).lowercased()
        text = ns.replacingCharacters(in: match.range, with: "")
        switch token {
        case "p1", "high": return 1
        case "p2", "medium", "med": return 2
        case "p3", "low": return 3
        case "p4": return 4
        default: return nil
        }
    }

    // MARK: - Labels

    private static let tagRegex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)#([\p{L}\p{N}_][\p{L}\p{N}_\-/]*)"#
    )

    private static func tagTokens(in text: String) -> [String] {
        guard let regex = tagRegex else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var labels: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 1))
            if seen.insert(label).inserted {
                labels.append(label)
            }
        }
        return labels
    }
}

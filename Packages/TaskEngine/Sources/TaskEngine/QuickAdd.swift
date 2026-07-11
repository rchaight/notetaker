import Foundation

/// One typed line → a filed markdown task. The standard capture path for
/// every surface (To-Do tab, menu bar, share extension, Siri in M9).
public struct QuickAddResult: Equatable, Sendable {
    /// Ready-to-append markdown, e.g. "- [ ] email dean #admin >2026-07-12 !p1".
    public let markdownLine: String
    public let metadata: ParsedTaskMetadata

    public init(markdownLine: String, metadata: ParsedTaskMetadata) {
        self.markdownLine = markdownLine
        self.metadata = metadata
    }
}

public enum QuickAddParser {
    /// Explicit tokens (>date !priority #tag &recurrence) always win; when
    /// absent, natural language fills in: NSDataDetector dates ("tomorrow",
    /// "next friday", "jul 20") and bare p1–p4 priorities.
    public static func parse(
        _ input: String,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> QuickAddResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var parsed = TaskTokenParser.parse(trimmed, today: today, calendar: calendar)
        var text = parsed.cleanText
        var dueDate = parsed.dueDate
        var priority = parsed.priority

        if priority == nil, let (bare, remaining) = extractBarePriority(from: text) {
            priority = bare
            text = remaining
        }
        if dueDate == nil, let (detected, remaining) = detectNaturalDate(in: text, calendar: calendar) {
            dueDate = detected
            text = remaining
        }

        text = text
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var line = "- [ ] \(text)"
        if let dueDate {
            line += " >\(dueDate)"
        }
        if let priority {
            line += " !p\(priority)"
        }
        if let recurrence = parsed.recurrence {
            line += " \(recurrence.rawToken)"
        }

        parsed = ParsedTaskMetadata(
            cleanText: text, dueDate: dueDate, priority: priority,
            labels: parsed.labels, recurrence: parsed.recurrence
        )
        return QuickAddResult(markdownLine: line, metadata: parsed)
    }

    // MARK: - Natural language pieces

    private static let barePriorityRegex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)[pP]([1-4])(?=$|\s)"#
    )

    private static func extractBarePriority(from text: String) -> (Int, String)? {
        guard let regex = barePriorityRegex else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let value = Int(ns.substring(with: match.range(at: 1)))
        else { return nil }
        return (value, ns.replacingCharacters(in: match.range, with: ""))
    }

    private static func detectNaturalDate(
        in text: String,
        calendar: Calendar
    ) -> (String, String)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let ns = text as NSString
        guard let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let date = match.date
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: date), ns.replacingCharacters(in: match.range, with: ""))
    }
}

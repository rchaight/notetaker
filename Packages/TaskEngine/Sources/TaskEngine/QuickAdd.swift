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
    /// Every grammar token the user typed is kept: `>date ~start !pN &rec
    /// ^id blockedby:^x @person ?kind ✅day` all survive, serialised in the
    /// one canonical order (`ParsedTaskMetadata.tokenSuffix`) after the task
    /// text — which keeps its `#tags` — so the same input in any token order
    /// yields the same line, and re-parsing that line changes nothing.
    ///
    /// Explicit `>date` / `!pN` tokens always win; when absent, natural
    /// language fills in: NSDataDetector dates ("tomorrow", "next friday",
    /// "jul 20") and bare p1–p4 priorities. `TaskTokenParser` is the only
    /// token parser here. `depends:^x` is written as `blockedby:^x`.
    public static func parse(
        _ input: String,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> QuickAddResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsed = TaskTokenParser.parse(trimmed, today: today, calendar: calendar)
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

        let metadata = ParsedTaskMetadata(
            cleanText: text, dueDate: dueDate, startDate: parsed.startDate,
            priority: priority, labels: parsed.labels, recurrence: parsed.recurrence,
            blockId: parsed.blockId, dependsOn: parsed.dependsOn,
            completedDay: parsed.completedDay, assignee: parsed.assignee, kind: parsed.kind
        )
        let tokens = metadata.tokenSuffix
        let line = "- [ ] " + text + (tokens.isEmpty ? "" : " " + tokens.joined(separator: " "))
        return QuickAddResult(markdownLine: line, metadata: metadata)
    }

    /// True when `input` carries any grammar token (due, start, priority,
    /// recurrence, `^id`, dependency, `@person`, `?kind`, `✅day`) — derived
    /// from `TaskTokenParser`, never a local pattern. Natural language
    /// ("tomorrow", bare "p1") and `#tags` do not count. Callers that offer
    /// a model-assisted parse use this to keep a model away from lines the
    /// exact parser can already file without dropping anything.
    public static func hasExplicitTokens(_ input: String) -> Bool {
        let parsed = TaskTokenParser.parse(input)
        return parsed.dueDate != nil || parsed.startDate != nil || parsed.priority != nil
            || parsed.recurrence != nil || parsed.blockId != nil || !parsed.dependsOn.isEmpty
            || parsed.assignee != nil || parsed.kind != nil || parsed.completedDay != nil
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

    #if os(Linux)
        /// swift-corelibs-foundation has no NSDataDetector. Linux fallback: only
        /// the bare words "today" / "tomorrow" (case-insensitive); phrases like
        /// "next friday" or "jul 20" are not detected (use `>date` tokens).
        private static func detectNaturalDate(
            in text: String,
            calendar: Calendar
        ) -> (String, String)? {
            guard let regex = try? NSRegularExpression(pattern: #"\b(today|tomorrow)\b"#, options: [.caseInsensitive])
            else { return nil }
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { return nil }
            let offset = ns.substring(with: match.range(at: 1)).lowercased() == "tomorrow" ? 1 : 0
            guard let date = calendar.date(byAdding: .day, value: offset, to: Date()) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return (formatter.string(from: date), ns.replacingCharacters(in: match.range, with: ""))
        }
    #else
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
    #endif
}

import Foundation

/// Outbound single-line edits beyond check-off: reschedule (>due / ~start)
/// and line removal. Pure text transforms over ONE raw task line — the
/// caller locates the line (TaskLineToggler.locate) and writes the file.
/// Every rewrite touches only its own token; the rest of the line keeps
/// its exact bytes.
public enum TaskLineRewriter {
    /// The raw line with its `>due` token replaced/added/removed.
    /// `nil` due removes the token. Insertion goes before any trailing
    /// tokens would be fine anywhere — appended at the end for simplicity.
    public static func settingDueDate(_ rawLine: String, to isoDay: String?) -> String {
        setToken(rawLine, prefix: ">", value: isoDay)
    }

    /// Same for the `~start` token.
    public static func settingStartDate(_ rawLine: String, to isoDay: String?) -> String {
        setToken(rawLine, prefix: "~", value: isoDay)
    }

    /// Appends `^id` when the line has none; returns (line, id). A slug is
    /// derived from the task text when `preferred` is nil.
    public static func ensuringBlockId(
        _ rawLine: String, preferred: String? = nil
    ) -> (line: String, id: String) {
        let parsed = TaskTokenParser.parse(
            String(rawLine.drop { $0 == " " || $0 == "\t" })
        )
        if let existing = parsed.blockId {
            return (rawLine, existing)
        }
        let slugSource = preferred ?? parsed.cleanText
        var slug = slugSource.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, ch in
                if ch != "-" || partial.last != "-" { partial.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        slug = String(slug.prefix(24))
        if slug.isEmpty { slug = "task" }
        return (appending(rawLine, token: "^" + slug), slug)
    }

    /// The raw line with its `!priority` token replaced/added/removed.
    public static func settingPriority(_ rawLine: String, to priority: Int?) -> String {
        let pattern = #"(?<=^|\s)!(p[1-4]|high|medium|low)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return rawLine }
        let ns = rawLine as NSString
        let match = regex.firstMatch(in: rawLine, range: NSRange(location: 0, length: ns.length))
        if let match {
            if let priority {
                return ns.replacingCharacters(in: match.range, with: "!p\(priority)")
            }
            var removal = match.range
            if removal.location > 0, ns.character(at: removal.location - 1) == 0x20 {
                removal = NSRange(location: removal.location - 1, length: removal.length + 1)
            }
            return ns.replacingCharacters(in: removal, with: "")
        }
        guard let priority else { return rawLine }
        return appending(rawLine, token: "!p\(priority)")
    }

    /// Appends `#label` (no-op when the label is already on the line).
    public static func addingLabel(_ rawLine: String, label: String) -> String {
        let parsed = TaskTokenParser.parse(String(rawLine.drop { $0 == " " || $0 == "\t" }))
        guard !parsed.labels.contains(label) else { return rawLine }
        return appending(rawLine, token: "#" + label)
    }

    /// Appends `blockedby:^id` (no-op when already referenced).
    public static func addingDependency(_ rawLine: String, on blockId: String) -> String {
        let parsed = TaskTokenParser.parse(
            String(rawLine.drop { $0 == " " || $0 == "\t" })
        )
        guard !parsed.dependsOn.contains(blockId) else { return rawLine }
        return appending(rawLine, token: "blockedby:^" + blockId)
    }

    private static func appending(_ rawLine: String, token: String) -> String {
        let trailingWhitespace = String(rawLine.reversed().prefix { $0 == " " || $0 == "\r" }.reversed())
        let body = String(rawLine.dropLast(trailingWhitespace.count))
        return body + " " + token + trailingWhitespace
    }

    private static func setToken(_ rawLine: String, prefix: String, value: String?) -> String {
        let pattern = "(?<=^|\\s)\(NSRegularExpression.escapedPattern(for: prefix))(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|[0-9]{4}-[0-9]{2}-[0-9]{2})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return rawLine }
        let ns = rawLine as NSString
        let match = regex.firstMatch(in: rawLine, range: NSRange(location: 0, length: ns.length))

        // Trailing carriage returns / whitespace must survive byte-exactly.
        let trailingWhitespace = String(rawLine.reversed().prefix { $0 == " " || $0 == "\r" }.reversed())
        let body = String(rawLine.dropLast(trailingWhitespace.count))

        if let match {
            if let value {
                return ns.replacingCharacters(in: match.range, with: prefix + value)
            }
            // Remove the token and one adjacent space.
            var removal = match.range
            if removal.location > 0, ns.character(at: removal.location - 1) == 0x20 {
                removal = NSRange(location: removal.location - 1, length: removal.length + 1)
            }
            return ns.replacingCharacters(in: removal, with: "")
        }
        guard let value else { return rawLine }
        return body + " " + prefix + value + trailingWhitespace
    }
}

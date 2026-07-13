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

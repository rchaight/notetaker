import Foundation

/// Outbound sync primitive: flip a task's checkbox by editing its source
/// line. Never blind-writes — the caller passes the rawLine it indexed, and
/// if the file drifted (external edit moved or changed the line) we either
/// relocate it by exact match or refuse, letting the caller re-index.
public enum TaskLineToggler {
    public struct Result: Equatable, Sendable {
        public let contents: String
        /// Where the task actually was (may differ from the anchor when the
        /// line moved).
        public let line: Int
        public let nowChecked: Bool
    }

    public static func toggle(
        contents: String,
        anchorLine: Int,
        expectedRawLine: String
    ) -> Result? {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let target: Int
        if anchorLine >= 0, anchorLine < lines.count, lines[anchorLine] == expectedRawLine {
            target = anchorLine
        } else if let relocated = lines.firstIndex(of: expectedRawLine) {
            // Line moved (edits above it) — same content, new position.
            target = relocated
        } else {
            return nil // drifted: content changed under us, refuse
        }

        guard let (flipped, nowChecked) = flipCheckbox(in: lines[target]) else { return nil }
        lines[target] = flipped
        return Result(contents: lines.joined(separator: "\n"), line: target, nowChecked: nowChecked)
    }

    /// Flips the first checkbox token on the line.
    private static func flipCheckbox(in line: String) -> (String, Bool)? {
        let ns = line as NSString
        if let range = firstRange(of: "[ ]", in: ns) {
            return (ns.replacingCharacters(in: range, with: "[x]"), true)
        }
        for token in ["[x]", "[X]"] {
            if let range = firstRange(of: token, in: ns) {
                return (ns.replacingCharacters(in: range, with: "[ ]"), false)
            }
        }
        return nil
    }

    private static func firstRange(of token: String, in line: NSString) -> NSRange? {
        let range = line.range(of: token)
        return range.location == NSNotFound ? nil : range
    }
}

import Foundation

/// Outbound sync primitive: find a task's source line and replace it. Never
/// blind-writes — the caller passes the rawLine it indexed, and if the file
/// drifted (external edit moved or changed the line) we either relocate it
/// by exact match or refuse, letting the caller re-index.
///
/// What the new line says is NOT decided here: completion lives in
/// `TaskEngine.RecurrenceEngine.completeTaskLine` (one primitive for every
/// surface), edits in `TaskLineRewriter`. This type only addresses lines.
public enum TaskLineToggler {
    /// Finds the anchored line (or its relocated exact match); nil = drifted.
    public static func locate(
        contents: String,
        anchorLine: Int,
        expectedRawLine: String
    ) -> Int? {
        locate(in: splitLines(contents), anchorLine: anchorLine, expectedRawLine: expectedRawLine)
    }

    /// Contents with `line` removed entirely (the line and its newline).
    public static func removingLine(_ contents: String, at line: Int) -> String {
        var lines = splitLines(contents)
        guard line >= 0, line < lines.count else { return contents }
        lines.remove(at: line)
        return lines.joined(separator: "\n")
    }

    /// Replaces one whole line, preserving every other byte.
    public static func replacingLine(_ contents: String, at line: Int, with newLine: String) -> String {
        var lines = splitLines(contents)
        guard line >= 0, line < lines.count else { return contents }
        lines[line] = newLine
        return lines.joined(separator: "\n")
    }

    private static func locate(in lines: [String], anchorLine: Int, expectedRawLine: String) -> Int? {
        if anchorLine >= 0, anchorLine < lines.count, lines[anchorLine] == expectedRawLine {
            return anchorLine
        }
        return lines.firstIndex(of: expectedRawLine)
    }
}

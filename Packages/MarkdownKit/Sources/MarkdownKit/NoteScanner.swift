import Foundation

/// A task line found in a note body.
public struct ScannedTask: Equatable, Sendable {
    /// 0-based line number within the scanned text.
    public let line: Int
    public let rawLine: String
    public let checked: Bool
    /// The task text after the checkbox token.
    public let text: String
    /// Leading whitespace width (tab = 4) — nesting depth for subtasks.
    public let indent: Int

    public init(line: Int, rawLine: String, checked: Bool, text: String, indent: Int = 0) {
        self.line = line
        self.rawLine = rawLine
        self.checked = checked
        self.text = text
        self.indent = indent
    }
}

/// Line-oriented extraction for the indexer. Line-based (not AST) because
/// the index anchors outbound writes to line numbers — the scanner and the
/// writer must agree on what a "line" is.
public enum NoteScanner {
    private static let taskRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:[-*+]|[0-9]+[.)])\s+\[( |x|X)\]\s+(.+)$"#
    )
    private static let wikilinkRegex = try? NSRegularExpression(
        pattern: #"\[\[([^\[\]\|#]+)(?:#[^\]\|]*)?(?:\|[^\]]*)?\]\]"#
    )
    private static let tagRegex = try? NSRegularExpression(
        pattern: #"(?<=^|\s)#([\p{L}\p{N}_][\p{L}\p{N}_\-/]*)"#
    )

    public static func tasks(in text: String) -> [ScannedTask] {
        guard let regex = taskRegex else { return [] }
        var tasks: [ScannedTask] = []
        for (index, rawLine) in splitLines(text).enumerated() {
            // Match against the CR-stripped copy; report rawLine untouched so
            // outbound line edits stay byte-exact on CRLF files.
            let line = strippingCarriageReturn(rawLine)
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            let ns = line as NSString
            let stateChar = ns.substring(with: match.range(at: 1))
            var indent = 0
            for character in line {
                if character == " " {
                    indent += 1
                } else if character == "\t" {
                    indent += 4
                } else {
                    break
                }
            }
            tasks.append(ScannedTask(
                line: index,
                rawLine: rawLine,
                checked: stateChar.lowercased() == "x",
                text: ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces),
                indent: indent
            ))
        }
        return tasks
    }

    /// [[Target]], [[Target|alias]], [[Target#heading]] → "Target", deduped
    /// in order of first appearance.
    public static func wikilinkTargets(in text: String) -> [String] {
        guard let regex = wikilinkRegex else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var targets: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty, seen.insert(target).inserted {
                targets.append(target)
            }
        }
        return targets
    }

    /// #tag and #nested/tag tokens, deduped, without the leading '#'.
    public static func tags(in text: String) -> [String] {
        guard let regex = tagRegex else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var tags: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1))
            if seen.insert(tag).inserted {
                tags.append(tag)
            }
        }
        return tags
    }
}

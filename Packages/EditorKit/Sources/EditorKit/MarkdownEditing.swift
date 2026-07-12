import Foundation

/// A formatting-bar command. Every operation is a plain markdown text
/// edit — WYSIWYG affordances, files stay CommonMark.
public enum EditorCommand: Equatable, Sendable {
    /// Bold/italic/code/strike: wrap or unwrap the selection.
    case wrap(prefix: String, suffix: String)
    /// "- ", "- [ ] ", "1. ": toggle on every line the selection touches.
    case toggleLinePrefix(String)
    /// 0 = body text; 1–6 = heading level for the current line(s).
    case setHeading(Int)
    /// [selection](url-placeholder) with the cursor on the placeholder.
    case link
}

/// The minimal edit to apply: replace `range` with `replacement`, then
/// select `selection` — small edits keep undo granular and cursors sane.
public struct EditResult: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange
}

public enum MarkdownEditing {
    public static func apply(
        _ command: EditorCommand, to text: String, selection: NSRange
    ) -> EditResult? {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }

        switch command {
        case let .wrap(prefix, suffix):
            return wrap(prefix: prefix, suffix: suffix, in: ns, selection: selection)
        case let .toggleLinePrefix(prefix):
            return toggleLinePrefix(prefix, in: ns, selection: selection)
        case let .setHeading(level):
            return setHeading(level, in: ns, selection: selection)
        case .link:
            let selected = ns.substring(with: selection)
            let label = selected.isEmpty ? "link text" : selected
            let replacement = "[\(label)](url)"
            let urlStart = selection.location + 1 + (label as NSString).length + 2
            return EditResult(
                range: selection, replacement: replacement,
                selection: NSRange(location: urlStart, length: 3)
            )
        }
    }

    private static func wrap(
        prefix: String, suffix: String, in ns: NSString, selection: NSRange
    ) -> EditResult {
        let p = prefix as NSString
        let s = suffix as NSString
        let selected = ns.substring(with: selection)

        // Unwrap when the selection is exactly wrapped already (inside or
        // including the markers).
        if selected.hasPrefix(prefix), selected.hasSuffix(suffix),
           (selected as NSString).length >= p.length + s.length {
            let inner = (selected as NSString).substring(
                with: NSRange(location: p.length, length: (selected as NSString).length - p.length - s.length)
            )
            return EditResult(
                range: selection, replacement: inner,
                selection: NSRange(location: selection.location, length: (inner as NSString).length)
            )
        }
        let before = selection.location >= p.length
            ? ns.substring(with: NSRange(location: selection.location - p.length, length: p.length))
            : ""
        let afterStart = NSMaxRange(selection)
        let after = afterStart + s.length <= ns.length
            ? ns.substring(with: NSRange(location: afterStart, length: s.length))
            : ""
        if before == prefix, after == suffix {
            // Markers sit just outside the selection: remove them.
            let range = NSRange(location: selection.location - p.length, length: selection.length + p.length + s.length)
            return EditResult(
                range: range, replacement: selected,
                selection: NSRange(location: range.location, length: selection.length)
            )
        }
        return EditResult(
            range: selection, replacement: prefix + selected + suffix,
            selection: NSRange(location: selection.location + p.length, length: selection.length)
        )
    }

    private static func toggleLinePrefix(
        _ prefix: String, in ns: NSString, selection: NSRange
    ) -> EditResult {
        let lineRange = ns.paragraphRange(for: selection)
        let block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.hasSuffix("\n") ? String(block.dropLast()).components(separatedBy: "\n")
            : block.components(separatedBy: "\n")

        let allPrefixed = lines.allSatisfy { line in
            line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(prefix) || line.trimmingCharacters(in: .whitespaces)
                .isEmpty
        }
        lines = lines.map { line in
            let indentEnd = line.prefix(while: { $0 == " " || $0 == "\t" })
            let rest = line.dropFirst(indentEnd.count)
            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return line
            }
            if allPrefixed {
                return rest.hasPrefix(prefix) ? String(indentEnd + rest.dropFirst(prefix.count)) : line
            }
            // Replace an existing list marker rather than stacking prefixes.
            var body = String(rest)
            for existing in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where body.hasPrefix(existing) {
                body = String(body.dropFirst(existing.count))
                break
            }
            return indentEnd + prefix + body
        }
        let replacement = lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
        return EditResult(
            range: lineRange, replacement: replacement,
            selection: NSRange(
                location: lineRange.location,
                length: (replacement as NSString).length - (hadTrailingNewline ? 1 : 0)
            )
        )
    }

    private static func setHeading(
        _ level: Int, in ns: NSString, selection: NSRange
    ) -> EditResult {
        let lineRange = ns.paragraphRange(for: selection)
        let block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        let lines = (hadTrailingNewline ? String(block.dropLast()) : block).components(separatedBy: "\n")

        let updated = lines.map { line -> String in
            var body = line.drop(while: { $0 == "#" })
            if body.first == " " {
                body = body.dropFirst()
            }
            guard level > 0 else { return String(body) }
            return String(repeating: "#", count: min(level, 6)) + " " + body
        }
        let replacement = updated.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
        return EditResult(
            range: lineRange, replacement: replacement,
            selection: NSRange(
                location: lineRange.location,
                length: (replacement as NSString).length - (hadTrailingNewline ? 1 : 0)
            )
        )
    }
}

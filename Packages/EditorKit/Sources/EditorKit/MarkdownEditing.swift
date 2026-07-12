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
    /// Insert a block (table, image line, rule) on its own paragraph after
    /// the cursor's, blank-line separated; cursor lands `cursorOffset` into
    /// the block (or after it when nil).
    case insertBlock(String, cursorOffset: Int?)
}

/// A one-shot command request: the UUID lets the editor execute exactly
/// once even though text mutation re-triggers view updates before the
/// binding clears (executing un-stamped commands in updateView loops
/// forever — learned the hard way).
public struct EditorCommandRequest: Equatable, Sendable {
    public let id: UUID
    public let command: EditorCommand

    public init(_ command: EditorCommand) {
        id = UUID()
        self.command = command
    }
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
        case let .insertBlock(block, cursorOffset):
            return insertBlock(block, cursorOffset: cursorOffset, in: ns, selection: selection)
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

    private static func insertBlock(
        _ block: String, cursorOffset: Int?, in ns: NSString, selection: NSRange
    ) -> EditResult {
        let paragraph = ns.paragraphRange(for: selection)
        let line = ns.substring(with: paragraph)
        let location: Int
        let replacement: String
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The cursor's line is empty — the block takes its place.
            location = paragraph.location
            replacement = block + "\n"
        } else {
            location = NSMaxRange(paragraph)
            // A paragraph at EOF has no trailing newline to build on.
            replacement = (line.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
        }
        let blockStart = location
            + (replacement as NSString).length - (block as NSString).length - 1
        let cursor = cursorOffset.map { blockStart + min($0, (block as NSString).length) }
            ?? location + (replacement as NSString).length
        return EditResult(
            range: NSRange(location: location, length: 0),
            replacement: replacement,
            selection: NSRange(location: cursor, length: 0)
        )
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

// MARK: - List typing behaviors

public extension MarkdownEditing {
    /// Pressing Return inside a list item: continue the list with the next
    /// prefix (same bullet, incremented number, fresh "[ ]"), or — when the
    /// item is empty — end the list by stripping the prefix. nil = plain
    /// newline.
    static func newlineContinuation(in text: String, selection: NSRange) -> EditResult? {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }
        let lineRange = ns.paragraphRange(for: NSRange(location: selection.location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }

        guard let item = parseListPrefix(line) else { return nil }

        let contentAfterPrefix = line.dropFirst(item.indent.count + item.prefix.count)
        if contentAfterPrefix.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: Return ends the list (strip the prefix, keep line).
            let prefixRange = NSRange(
                location: lineRange.location + (item.indent as NSString).length,
                length: (item.prefix as NSString).length
            )
            return EditResult(
                range: prefixRange, replacement: "",
                selection: NSRange(location: prefixRange.location, length: 0)
            )
        }

        let insertion = "\n" + item.indent + item.continuationPrefix
        return EditResult(
            range: selection, replacement: insertion,
            selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0)
        )
    }

    /// Tab / Shift-Tab on list lines: nest or un-nest by two spaces.
    /// nil when the selection isn't on list items (caller inserts a tab).
    static func indentListItems(in text: String, selection: NSRange, outdent: Bool) -> EditResult? {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }
        let lineRange = ns.paragraphRange(for: selection)
        let block = ns.substring(with: lineRange)
        let hadNewline = block.hasSuffix("\n")
        let lines = (hadNewline ? String(block.dropLast()) : block).components(separatedBy: "\n")
        guard lines.contains(where: { parseListPrefix($0) != nil }) else { return nil }

        let updated = lines.map { line -> String in
            guard parseListPrefix(line) != nil else { return line }
            if outdent {
                if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
                if line.hasPrefix("\t") { return String(line.dropFirst(1)) }
                return line
            }
            return "  " + line
        }
        let replacement = updated.joined(separator: "\n") + (hadNewline ? "\n" : "")
        let delta = (replacement as NSString).length - (block as NSString).length
        return EditResult(
            range: lineRange, replacement: replacement,
            selection: NSRange(
                location: max(lineRange.location, selection.location + (outdent ? max(delta, -2) : 2)),
                length: selection.length
            )
        )
    }

    struct ListPrefixInfo {
        public let indent: String
        public let prefix: String
        public let continuationPrefix: String
    }

    /// Recognizes task, bullet, and ordered prefixes (in that order).
    static func parseListPrefix(_ line: String) -> ListPrefixInfo? {
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = line.dropFirst(indent.count)
        for task in ["- [ ] ", "- [x] ", "- [X] "] where rest.hasPrefix(task) {
            return ListPrefixInfo(indent: indent, prefix: task, continuationPrefix: "- [ ] ")
        }
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return ListPrefixInfo(indent: indent, prefix: bullet, continuationPrefix: bullet)
        }
        if let match = rest.prefixMatch(of: #/(?<num>[0-9]+)(?<sep>[.)]) /#) {
            let next = (Int(match.num) ?? 0) + 1
            return ListPrefixInfo(
                indent: indent,
                prefix: String(match.0),
                continuationPrefix: "\(next)\(match.sep) "
            )
        }
        return nil
    }
}

import Foundation

/// One `[[wikilink]]` (or `![[embed]]`) found in a text. The single parsed
/// form every surface shares: the indexer, the editor's styling, Reading
/// mode, ⌘-click and Rename's link rewrite all go through `WikilinkSyntax`
/// instead of carrying a regex of their own.
public struct Wikilink: Equatable, Sendable, Hashable {
    /// Text between the brackets, untrimmed.
    public let raw: String
    /// Path-or-title part, trimmed. Empty for a self link such as `[[#Heading]]`.
    public let target: String
    /// After `#`, before `|`, unless it starts with `^` (that is a block id).
    public let heading: String?
    /// After `#^`.
    public let blockId: String?
    /// After the first `|`.
    public let alias: String?
    /// Preceded by `!`.
    public let isEmbed: Bool
    /// The whole `[[…]]` (or `![[…]]`), in the scanned string's UTF-16 coordinates.
    public let range: NSRange
    /// The trimmed target characters inside `range`.
    public let targetRange: NSRange

    public init(
        raw: String,
        target: String,
        heading: String?,
        blockId: String?,
        alias: String?,
        isEmbed: Bool,
        range: NSRange,
        targetRange: NSRange
    ) {
        self.raw = raw
        self.target = target
        self.heading = heading
        self.blockId = blockId
        self.alias = alias
        self.isEmbed = isEmbed
        self.range = range
        self.targetRange = targetRange
    }

    /// The last `/` component of `target` — the note's title.
    public var title: String {
        (target.components(separatedBy: "/").last ?? target)
            .trimmingCharacters(in: .whitespaces)
    }

    /// What Reading mode displays: the alias if there is one, otherwise the
    /// title (with `› heading` for a heading link). A self link such as
    /// `[[#Budget]]` has no title, so it shows just the heading.
    public var label: String {
        if let alias {
            return alias
        }
        if let heading {
            return title.isEmpty ? heading : "\(title) › \(heading)"
        }
        if title.isEmpty, let blockId {
            return "^\(blockId)"
        }
        return title
    }
}

public enum WikilinkSyntax {
    private static let regex = try? NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]+?)\]\]"#)

    private static let pipe: unichar = 0x7C
    private static let hash: unichar = 0x23
    private static let caret: unichar = 0x5E

    /// Every link in `text`, in order. A match overlapping any `excluding`
    /// range (typically code spans and fenced blocks) is skipped — callers
    /// that want code to stay literal pass those ranges in; the parser itself
    /// does not know about code.
    public static func links(in text: String, excluding: [NSRange] = []) -> [Wikilink] {
        guard let regex else { return [] }
        let ns = text as NSString
        var result: [Wikilink] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if excluding.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                continue
            }
            let innerRange = match.range(at: 2)
            let raw = ns.substring(with: innerRange)
            let parts = split(raw)
            // `[[ ]]` / `[[|alias]]` point at nothing.
            guard !parts.target.isEmpty || parts.heading != nil || parts.blockId != nil else { continue }
            result.append(Wikilink(
                raw: raw,
                target: parts.target,
                heading: parts.heading,
                blockId: parts.blockId,
                alias: parts.alias,
                isEmbed: match.range(at: 1).length > 0,
                range: match.range,
                targetRange: NSRange(
                    location: innerRange.location + parts.targetOffset,
                    length: parts.target.utf16.count
                )
            ))
        }
        return result
    }

    /// Splits the text between the brackets. The first `|` starts the alias
    /// (it may contain more `|` and `#`); the first `#` before it starts the
    /// heading, or the block id when the fragment begins with `^`.
    public static func parse(inner raw: String)
        -> (target: String, heading: String?, blockId: String?, alias: String?) {
        let parts = split(raw)
        return (parts.target, parts.heading, parts.blockId, parts.alias)
    }

    /// Replaces the target of every link whose `title` equals `old`
    /// (case-insensitive) with `new`, keeping any path prefix, heading, block
    /// id, alias and surrounding whitespace. Returns the new text and the
    /// number of links changed. Pure; idempotent. A link whose title already
    /// reads exactly `new` is not counted. Self links (`[[#Heading]]`) are
    /// never rewritten.
    public static func rewrite(
        _ text: String,
        renamingTitle old: String,
        to new: String,
        excluding: [NSRange] = []
    ) -> (text: String, count: Int) {
        let oldTitle = old.trimmingCharacters(in: .whitespaces)
        guard !oldTitle.isEmpty, !new.trimmingCharacters(in: .whitespaces).isEmpty else { return (text, 0) }
        var result = text as NSString
        var count = 0
        for link in links(in: text, excluding: excluding).reversed() {
            let title = link.title
            guard !title.isEmpty,
                  title.compare(oldTitle, options: .caseInsensitive) == .orderedSame,
                  title != new
            else { continue }
            // The title is the tail of the (right-trimmed) target, so the
            // path prefix before it stays as written.
            let titleLength = title.utf16.count
            let titleRange = NSRange(
                location: NSMaxRange(link.targetRange) - titleLength, length: titleLength
            )
            result = result.replacingCharacters(in: titleRange, with: new) as NSString
            count += 1
        }
        return (result as String, count)
    }

    /// Title resolution shared by every click site. A path-qualified target
    /// (`Projects/Plan`) matches the note id `Projects/Plan.md` first; else
    /// the notes titled `link.title` (case-insensitive) are the candidates.
    /// Several candidates: the one in `sourceId`'s folder, else the shortest
    /// id, else lexicographic. Nil when nothing matches.
    public static func resolve(
        _ link: Wikilink,
        among notes: [(id: String, title: String)],
        from sourceId: String?
    ) -> String? {
        if link.target.contains("/") {
            let wanted = link.target + ".md"
            if let hit = notes.first(where: {
                $0.id.compare(wanted, options: .caseInsensitive) == .orderedSame
            }) {
                return hit.id
            }
        }
        let title = link.title
        guard !title.isEmpty else { return nil }
        let candidates = notes.filter {
            $0.title.compare(title, options: .caseInsensitive) == .orderedSame
        }
        guard candidates.count > 1 else { return candidates.first?.id }
        var pool = candidates
        if let sourceId {
            let folder = folder(of: sourceId)
            let sameFolder = candidates.filter {
                self.folder(of: $0.id).compare(folder, options: .caseInsensitive) == .orderedSame
            }
            if !sameFolder.isEmpty {
                pool = sameFolder
            }
        }
        return pool.min {
            ($0.id.count, $0.id) < ($1.id.count, $1.id)
        }?.id
    }

    /// 0-based line of a heading (text after the `#`s, trimmed,
    /// case-insensitive) or a block id (a line ending in `^id`). Lines inside
    /// frontmatter and fenced code are skipped; the first hit wins.
    public static func anchorLine(heading: String?, blockId: String?, in text: String) -> Int? {
        let wantedHeading = heading?.trimmingCharacters(in: .whitespaces)
        let wantedBlock = blockId?.trimmingCharacters(in: .whitespaces)
        let hasHeading = !(wantedHeading ?? "").isEmpty
        let hasBlock = !(wantedBlock ?? "").isEmpty
        guard hasHeading || hasBlock else { return nil }

        var fence: String?
        for (index, rawLine) in splitLines(text).enumerated() {
            let line = strippingCarriageReturn(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0, trimmed == "---" {
                fence = "---"
                continue
            }
            if let open = fence {
                if open == "---" {
                    if trimmed == "---" || trimmed == "..." {
                        fence = nil
                    }
                } else if trimmed.hasPrefix(open) {
                    fence = nil
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            if hasHeading, let wantedHeading, let title = headingText(of: trimmed),
               title.compare(wantedHeading, options: .caseInsensitive) == .orderedSame {
                return index
            }
            if hasBlock, let wantedBlock, endsWithBlockId(trimmed, wantedBlock) {
                return index
            }
        }
        return nil
    }

    // MARK: Internals

    private struct Parts {
        var target: String
        var targetOffset: Int
        var heading: String?
        var blockId: String?
        var alias: String?
    }

    private static func split(_ raw: String) -> Parts {
        let ns = raw as NSString
        let length = ns.length
        var pipeIndex = length
        for offset in 0 ..< length where ns.character(at: offset) == pipe {
            pipeIndex = offset
            break
        }
        var hashIndex: Int?
        for offset in 0 ..< pipeIndex where ns.character(at: offset) == hash {
            hashIndex = offset
            break
        }
        let targetEnd = hashIndex ?? pipeIndex

        var start = 0
        while start < targetEnd, isWhitespace(ns.character(at: start)) {
            start += 1
        }
        var stop = targetEnd
        while stop > start, isWhitespace(ns.character(at: stop - 1)) {
            stop -= 1
        }
        let target = ns.substring(with: NSRange(location: start, length: stop - start))

        var heading: String?
        var blockId: String?
        if let hashIndex {
            let fragment = ns.substring(with: NSRange(
                location: hashIndex + 1, length: pipeIndex - hashIndex - 1
            )).trimmingCharacters(in: .whitespaces)
            if fragment.utf16.first == caret {
                let id = String(fragment.dropFirst()).trimmingCharacters(in: .whitespaces)
                blockId = id.isEmpty ? nil : id
            } else if !fragment.isEmpty {
                heading = fragment
            }
        }

        var alias: String?
        if pipeIndex < length {
            let text = ns.substring(from: pipeIndex + 1).trimmingCharacters(in: .whitespaces)
            alias = text.isEmpty ? nil : text
        }
        return Parts(target: target, targetOffset: start, heading: heading, blockId: blockId, alias: alias)
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private static func folder(of id: String) -> String {
        (id as NSString).deletingLastPathComponent
    }

    /// `## Budget` → "Budget"; nil when the line isn't an ATX heading.
    private static func headingText(of trimmedLine: String) -> String? {
        var hashes = 0
        for character in trimmedLine {
            guard character == "#" else { break }
            hashes += 1
        }
        guard (1 ... 6).contains(hashes) else { return nil }
        let rest = trimmedLine.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func endsWithBlockId(_ trimmedLine: String, _ id: String) -> Bool {
        let suffix = "^" + id
        guard trimmedLine.hasSuffix(suffix) else { return false }
        let before = trimmedLine.dropLast(suffix.count)
        return before.isEmpty || before.last == " " || before.last == "\t"
    }
}

import Foundation

/// Detects an in-progress `#tag` or `[[wikilink` token at the cursor so the
/// editor can offer completions. Pure text math — the platform coordinator
/// drives the actual completion UI.
public enum AutocompleteContext {
    public enum Kind: Equatable, Sendable {
        case tag
        case wikilink
    }

    public struct Match: Equatable, Sendable {
        public let kind: Kind
        /// Everything typed after the trigger ("#" or "[["), up to the cursor.
        public let query: String
    }

    static let tagCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-/"))

    /// The open token containing `cursor`, if any. Scans back within the
    /// cursor's line (bounded) for the nearest unclosed trigger.
    public static func match(in text: String, cursor: Int) -> Match? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let paragraph = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
        let start = max(paragraph.location, cursor - 256)
        let head = ns.substring(with: NSRange(location: start, length: cursor - start))

        // Wikilink: an unclosed "[[" before the cursor with no "]]" after it.
        if let open = head.range(of: "[[", options: .backwards) {
            let after = String(head[open.upperBound...])
            if !after.contains("]]"), !after.contains("[[") {
                return Match(kind: .wikilink, query: after)
            }
        }
        // Tag: "#" preceded by start-of-line/whitespace, tag charset since.
        var index = head.endIndex
        var body = ""
        while index > head.startIndex {
            let previous = head.index(before: index)
            let character = head[previous]
            if character == "#" {
                let atStart = previous == head.startIndex
                if atStart || head[head.index(before: previous)].isWhitespace {
                    return Match(kind: .tag, query: body)
                }
                return nil
            }
            guard character.unicodeScalars.allSatisfy({ tagCharacters.contains($0) }) else {
                return nil
            }
            body = String(character) + body
            index = previous
        }
        return nil
    }

    /// Completion strings aligned to the system's partial-word range: the
    /// full query may start before it (e.g. "project/al" when the partial
    /// word is just "al"), so candidates are trimmed to the partial start.
    /// `suffix` closes the token ("]]" for wikilinks).
    public static func completionStrings(
        query: String, partialLength: Int, candidates: [String], appending suffix: String = ""
    ) -> [String] {
        let lowered = query.lowercased()
        let drop = max(query.count - partialLength, 0)
        return candidates
            .filter { lowered.isEmpty || $0.lowercased().hasPrefix(lowered) }
            .filter { $0.lowercased() != lowered }
            .map { String($0.dropFirst(drop)) + suffix }
    }
}

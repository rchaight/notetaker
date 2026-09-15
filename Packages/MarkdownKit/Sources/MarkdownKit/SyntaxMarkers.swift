import Foundation

/// Locates the syntax-marker spans (the `**`, `*`, `~~`, backticks, `#` and
/// link plumbing) inside styled ranges, so the editor can hide them off the
/// cursor line in Live Preview. Pure text math — no styling here.
public enum SyntaxMarkers {
    /// The markers of one styled span, kept together so a caller can reveal
    /// a single span's delimiters instead of a whole paragraph's.
    public struct MarkerGroup: Equatable, Sendable {
        /// The styled span the markers delimit.
        public let span: NSRange
        /// What the span is — reveal rules differ by kind.
        public let kind: MarkdownElementKind
        /// Line-level syntax (heading hashes, blockquote prefixes, code
        /// fences) belongs to a line rather than to an inline span, so the
        /// editor reveals it with the caret's line, not with a span.
        public let isBlockLevel: Bool
        /// Delimiter ranges, in the same UTF-16 coordinates as `span`.
        public let markers: [NSRange]

        public init(span: NSRange, kind: MarkdownElementKind, isBlockLevel: Bool, markers: [NSRange]) {
            self.span = span
            self.kind = kind
            self.isBlockLevel = isBlockLevel
            self.markers = markers
        }
    }

    /// Marker spans for the given styled ranges, in the same UTF-16
    /// coordinates. Ranges whose delimiters can't be confirmed in the text
    /// are skipped (defensive against parser/source drift).
    public static func markerRanges(in text: String, styled: [StyledRange]) -> [NSRange] {
        markerGroups(in: text, styled: styled).flatMap(\.markers)
    }

    /// The same markers as `markerRanges(in:styled:)`, grouped by the span
    /// that owns them and tagged block- or inline-level — what Live Preview
    /// needs to reveal one span at a time.
    public static func markerGroups(in text: String, styled: [StyledRange]) -> [MarkerGroup] {
        let ns = text as NSString
        var groups: [MarkerGroup] = []

        for item in styled {
            guard NSMaxRange(item.range) <= ns.length else { continue }
            var markers: [NSRange] = []
            var isBlockLevel = false
            switch item.kind {
            case .heading:
                // "## Title" (up to 3 leading spaces is still a valid ATX
                // heading) — hide indent + hashes + the following space.
                isBlockLevel = true
                let prefix = ns.substring(with: item.range)
                var lead = 0
                for character in prefix {
                    if character == " ", lead < 3 {
                        lead += 1
                    } else {
                        break
                    }
                }
                var hashes = 0
                for character in prefix.dropFirst(lead) {
                    if character == "#" {
                        hashes += 1
                    } else {
                        break
                    }
                }
                if hashes > 0 {
                    let extra = prefix.dropFirst(lead + hashes).first == " " ? 1 : 0
                    markers.append(NSRange(location: item.range.location, length: lead + hashes + extra))
                }
            case .strong:
                appendSymmetric(item.range, in: ns, delimiterLength: 2, allowed: ["*", "_"], to: &markers)
            case .emphasis:
                appendSymmetric(item.range, in: ns, delimiterLength: 1, allowed: ["*", "_"], to: &markers)
            case .strikethrough:
                appendSymmetric(item.range, in: ns, delimiterLength: 2, allowed: ["~"], to: &markers)
            case .inlineCode:
                // `code` or ``code`` — count the actual backtick run.
                let content = ns.substring(with: item.range)
                var ticks = 0
                for character in content {
                    if character == "`" {
                        ticks += 1
                    } else {
                        break
                    }
                }
                if ticks > 0, content.count >= ticks * 2 {
                    markers.append(NSRange(location: item.range.location, length: ticks))
                    markers.append(NSRange(location: NSMaxRange(item.range) - ticks, length: ticks))
                }
            case .blockQuote:
                // Hide every line's "> " prefix (including nested "> > ").
                isBlockLevel = true
                appendLinePrefixMarkers(
                    pattern: "^ {0,3}(?:> ?)+",
                    range: item.range, in: ns, to: &markers
                )
            case let .codeBlock(language):
                // Fenced blocks: hide the opening ```lang and closing ```
                // lines. Indented code blocks have no fence to hide.
                isBlockLevel = true
                let content = ns.substring(with: item.range)
                guard content.hasPrefix("```") || content.hasPrefix("~~~") else { continue }
                _ = language
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                if let first = lines.first {
                    markers.append(NSRange(
                        location: item.range.location,
                        length: String(first).utf16.count
                    ))
                }
                if lines.count > 1 {
                    let last = lines.last.map(String.init) ?? ""
                    let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                        markers.append(NSRange(
                            location: NSMaxRange(item.range) - last.utf16.count,
                            length: last.utf16.count
                        ))
                    }
                }
            case .wikilink:
                // [[Note Title]] — hide the double brackets.
                appendSymmetric(item.range, in: ns, delimiterLength: 2, allowed: ["[", "]"], to: &markers)
            case .highlightMark:
                // ==marked== — hide the equals runs; the tint carries meaning.
                appendSymmetric(item.range, in: ns, delimiterLength: 2, allowed: ["="], to: &markers)
            case .listItem:
                // Bullets and checkboxes render as glyphs via equal-length
                // display substitution (EditorKit); ordered numbers stay
                // visible by design. Nothing to hide here anymore.
                continue
            case .link:
                // [label](destination) — hide "[" and "](...)".
                let content = ns.substring(with: item.range)
                guard content.hasPrefix("["), content.hasSuffix(")"),
                      let closeBracket = content.range(of: "](")
                else { continue }
                let closeOffset = content.distance(from: content.startIndex, to: closeBracket.lowerBound)
                let closeUTF16 = String(content.prefix(closeOffset)).utf16.count
                markers.append(NSRange(location: item.range.location, length: 1))
                markers.append(NSRange(
                    location: item.range.location + closeUTF16,
                    length: item.range.length - closeUTF16
                ))
            default:
                continue
            }
            guard !markers.isEmpty else { continue }
            groups.append(MarkerGroup(
                span: item.range, kind: item.kind, isBlockLevel: isBlockLevel, markers: markers
            ))
        }

        // Nested constructs (e.g. "> > ") emit overlapping markers — keep
        // only the outermost span for each region.
        let all = groups.flatMap(\.markers)
        return groups.compactMap { group in
            let kept = group.markers.filter { candidate in
                !all.contains { other in
                    other != candidate
                        && NSIntersectionRange(other, candidate) == candidate
                        && other.length > candidate.length
                }
            }
            guard !kept.isEmpty else { return nil }
            return MarkerGroup(
                span: group.span, kind: group.kind, isBlockLevel: group.isBlockLevel, markers: kept
            )
        }
    }

    private static func appendLinePrefixMarkers(
        pattern: String,
        range: NSRange,
        in text: NSString,
        to markers: inout [NSRange],
        firstLineOnly: Bool = false
    ) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: firstLineOnly ? [] : [.anchorsMatchLines]
        ) else { return }
        let matches = regex.matches(in: text as String, range: range)
        for match in matches {
            markers.append(match.range)
            if firstLineOnly {
                break
            }
        }
    }

    private static func appendSymmetric(
        _ range: NSRange,
        in text: NSString,
        delimiterLength: Int,
        allowed: Set<Character>,
        to markers: inout [NSRange]
    ) {
        guard range.length >= delimiterLength * 2 else { return }
        let content = text.substring(with: range)
        let head = content.prefix(delimiterLength)
        let tail = content.suffix(delimiterLength)
        guard head.allSatisfy({ allowed.contains($0) }),
              tail.allSatisfy({ allowed.contains($0) })
        else { return }
        markers.append(NSRange(location: range.location, length: delimiterLength))
        markers.append(NSRange(location: NSMaxRange(range) - delimiterLength, length: delimiterLength))
    }
}

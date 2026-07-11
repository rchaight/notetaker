import Foundation

/// Locates the syntax-marker spans (the `**`, `*`, `~~`, backticks, `#` and
/// link plumbing) inside styled ranges, so the editor can hide them off the
/// cursor line in Live Preview. Pure text math — no styling here.
public enum SyntaxMarkers {
    /// Marker spans for the given styled ranges, in the same UTF-16
    /// coordinates. Ranges whose delimiters can't be confirmed in the text
    /// are skipped (defensive against parser/source drift).
    public static func markerRanges(in text: String, styled: [StyledRange]) -> [NSRange] {
        let ns = text as NSString
        var markers: [NSRange] = []

        for item in styled {
            guard NSMaxRange(item.range) <= ns.length else { continue }
            switch item.kind {
            case .heading:
                // "## Title" — hide hashes plus the following space.
                let prefix = ns.substring(with: item.range)
                var hashes = 0
                for character in prefix {
                    if character == "#" {
                        hashes += 1
                    } else {
                        break
                    }
                }
                if hashes > 0 {
                    let extra = prefix.dropFirst(hashes).first == " " ? 1 : 0
                    markers.append(NSRange(location: item.range.location, length: hashes + extra))
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
                appendLinePrefixMarkers(
                    pattern: "^ {0,3}(?:> ?)+",
                    range: item.range, in: ns, to: &markers
                )
            case let .codeBlock(language):
                // Fenced blocks: hide the opening ```lang and closing ```
                // lines. Indented code blocks have no fence to hide.
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
            case .listItem:
                // Hide the "- " / "* " / "1. " bullet; a task item then leads
                // with its visible [ ]/[x] checkbox token.
                appendLinePrefixMarkers(
                    pattern: "^ *(?:[-*+]|[0-9]+[.)]) ",
                    range: NSRange(location: item.range.location, length: min(item.range.length, 12)),
                    in: ns, to: &markers, firstLineOnly: true
                )
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
        }
        // Nested constructs (e.g. "> > ") emit overlapping markers — keep
        // only the outermost span for each region.
        return markers.filter { candidate in
            !markers.contains { other in
                other != candidate
                    && NSIntersectionRange(other, candidate) == candidate
                    && other.length > candidate.length
            }
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

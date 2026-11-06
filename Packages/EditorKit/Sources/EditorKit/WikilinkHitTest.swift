import Foundation
import MarkdownKit

/// Which `[[wikilink]]`, if any, a character index falls inside. Pure and
/// paragraph-local: a ⌘-click scans only the clicked paragraph, never the
/// whole note, and does not exclude code — opening a note from `[[x]]` inside
/// a code span is harmless, and keeping the click free of a parse keeps it
/// instant.
public enum WikilinkHitTest {
    /// The link whose `range` contains `index`, with `range`/`targetRange`
    /// shifted into `text`'s coordinates (UTF-16, like `NSTextView`).
    public static func link(at index: Int, in text: String) -> Wikilink? {
        let ns = text as NSString
        guard index >= 0, index <= ns.length else { return nil }
        let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
        let slice = ns.substring(with: paragraph)
        for link in WikilinkSyntax.links(in: slice) {
            let range = NSRange(location: link.range.location + paragraph.location, length: link.range.length)
            guard NSLocationInRange(index, range) else { continue }
            return Wikilink(
                raw: link.raw,
                target: link.target,
                heading: link.heading,
                blockId: link.blockId,
                alias: link.alias,
                isEmbed: link.isEmbed,
                range: range,
                targetRange: NSRange(
                    location: link.targetRange.location + paragraph.location,
                    length: link.targetRange.length
                )
            )
        }
        return nil
    }
}

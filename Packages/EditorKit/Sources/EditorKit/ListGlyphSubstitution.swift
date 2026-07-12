import Foundation
import MarkdownKit

/// Display-only glyph rendering for list markers via TextKit 2 paragraph
/// substitution. CRITICAL INVARIANT: every swap is EQUAL LENGTH in UTF-16,
/// so display offsets match backing-store offsets 1:1 — cursor math,
/// selections, and checkbox-click ranges all stay valid. The file never
/// changes; delete into a marker and the raw syntax reappears.
public enum ListGlyphSubstitution {
    /// Figure space: visible-width spacer that keeps glyph rows aligned.
    static let pad = "\u{2007}"

    /// Returns a display paragraph with markers swapped for glyphs, or nil
    /// when the paragraph contains none (TextKit uses the original).
    public static func substituted(paragraph: NSAttributedString) -> NSAttributedString? {
        let text = paragraph.string
        let ns = text as NSString
        let indentEnd = text.prefix(while: { $0 == " " || $0 == "\t" }).count

        func swap(_ marker: String, with glyph: String) -> NSAttributedString? {
            guard text.dropFirst(indentEnd).hasPrefix(marker) else { return nil }
            let range = NSRange(location: indentEnd, length: (marker as NSString).length)
            assert((glyph as NSString).length == range.length, "substitution must be equal-length")
            let mutable = NSMutableAttributedString(attributedString: paragraph)
            mutable.replaceCharacters(in: range, with: glyph)
            // Re-assert the original attributes over the glyph (replace keeps
            // most, but be explicit so links/colors survive).
            paragraph.enumerateAttributes(in: range) { attributes, subrange, _ in
                mutable.addAttributes(attributes, range: subrange)
            }
            return mutable
        }

        // Order matters: task items start with "- " too. The glyph replaces
        // "[" — the FIRST character of the clickable token range — so the
        // toggle link and its styling land on the glyph, not on padding.
        if let swapped = swap("- [ ]", with: pad + pad + "☐" + pad + pad) { return swapped }
        if let swapped = swap("- [x]", with: pad + pad + "☑" + pad + pad) { return swapped }
        if let swapped = swap("- [X]", with: pad + pad + "☑" + pad + pad) { return swapped }
        if let swapped = swap("- ", with: "•" + pad) { return swapped }
        if let swapped = swap("* ", with: "•" + pad) { return swapped }
        if let swapped = swap("+ ", with: "•" + pad) { return swapped }
        _ = ns
        return nil
    }
}

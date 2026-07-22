import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Blockquote presentation: a rounded accent bar drawn down the paragraph's
/// left edge (Craft/GitHub-style). TextKit 2 custom drawing — the layout
/// delegate hands quote paragraphs this fragment class; text drawing itself
/// is untouched (super does it).
public final class QuoteBarLayoutFragment: NSTextLayoutFragment {
    /// Resolved at draw time from the theme the coordinator installs.
    public var barColor: PlatformColor = MarkdownTheme.default.quoteAccent

    override public func draw(at point: CGPoint, in context: CGContext) {
        let frame = layoutFragmentFrame
        let bar = CGRect(x: point.x + 2, y: point.y + 1, width: 3.5, height: max(frame.height - 2, 0))
        if bar.height > 0 {
            context.saveGState()
            let path = CGPath(
                roundedRect: bar, cornerWidth: 1.75, cornerHeight: 1.75, transform: nil
            )
            context.addPath(path)
            context.setFillColor(barColor.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// Thematic break presentation: `---`/`***`/`___` draw as a centered
/// hairline divider; the dash characters render clear off-cursor so only
/// the line shows.
public final class RuleLayoutFragment: NSTextLayoutFragment {
    public var lineColor: PlatformColor = MarkdownTheme.default.focusDimColor

    override public func draw(at point: CGPoint, in context: CGContext) {
        let frame = layoutFragmentFrame
        if frame.width > 12 {
            context.saveGState()
            context.setFillColor(lineColor.cgColor)
            context.fill(CGRect(
                x: point.x + 4, y: point.y + (frame.height / 2) - 0.5,
                width: frame.width - 12, height: 1
            ))
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// Draws rounded pill backgrounds behind #tag ranges — inset from the
/// line box so chips never kiss neighboring lines, with true rounded ends.
public final class TagChipLayoutFragment: NSTextLayoutFragment {
    /// Character ranges LOCAL to this fragment's element, with the tag color.
    public var chips: [(local: NSRange, color: PlatformColor)] = []
    /// Tag-font metrics: the pill hugs the GLYPHS (anchored to the text
    /// baseline), not the full line box — otherwise smaller tag text sits
    /// at the pill's bottom (user screenshot).
    public var glyphAscent: CGFloat = 12
    public var glyphDescent: CGFloat = -3

    override public func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        for chip in chips {
            for line in textLineFragments {
                let overlap = NSIntersectionRange(line.characterRange, chip.local)
                guard overlap.length > 0 else { continue }
                let start = line.locationForCharacter(at: overlap.location)
                let x0 = start.x
                let x1 = line.locationForCharacter(at: NSMaxRange(overlap)).x
                guard x1 > x0 else { continue }
                let baseline = start.y
                let pad: CGFloat = 2.5
                let rect = CGRect(
                    x: point.x + x0 - 4,
                    y: point.y + baseline - glyphAscent - pad,
                    width: x1 - x0 + 8,
                    height: glyphAscent - glyphDescent + pad * 2
                )
                context.addPath(CGPath(
                    roundedRect: rect,
                    cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                    transform: nil
                ))
                context.setFillColor(chip.color.withAlphaComponent(0.16).cgColor)
                context.fillPath()
            }
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

public enum ThematicBreakDetection {
    /// A thematic-break paragraph: ≤3 leading spaces, then 3+ of -/*/_
    /// (optionally space-separated, per CommonMark), nothing else.
    public static func isRuleParagraph(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard paragraph.prefix(while: { $0 == " " }).count <= 3 else { return false }
        guard let marker = trimmed.first, "-*_".contains(marker) else { return false }
        var count = 0
        for character in trimmed {
            if character == marker {
                count += 1
            } else if character != " " {
                return false
            }
        }
        return count >= 3
    }
}

public enum BlockquoteDetection {
    /// A markdown blockquote paragraph: up to 3 leading spaces, then ">".
    public static func isQuoteParagraph(_ paragraph: String) -> Bool {
        var spaces = 0
        for character in paragraph {
            if character == " " {
                spaces += 1
                if spaces > 3 {
                    return false
                }
            } else {
                return character == ">"
            }
        }
        return false
    }
}

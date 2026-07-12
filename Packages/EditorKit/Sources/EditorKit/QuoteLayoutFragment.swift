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

public enum BlockquoteDetection {
    /// A markdown blockquote paragraph: up to 3 leading spaces, then ">".
    public static func isQuoteParagraph(_ paragraph: String) -> Bool {
        var spaces = 0
        for character in paragraph {
            if character == " " {
                spaces += 1
                if spaces > 3 { return false }
            } else {
                return character == ">"
            }
        }
        return false
    }
}

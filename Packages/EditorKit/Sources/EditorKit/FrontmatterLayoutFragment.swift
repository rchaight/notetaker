import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Frontmatter presentation: each paragraph of the block draws its slice of
/// one rounded "properties card" (the top slice rounds the top corners, the
/// bottom slice the bottom). The card is identical whether or not the caret
/// is inside, and the `key: value` lines and `---` fences keep their line
/// count and line height in both states — the block used to collapse to a
/// hairline off-caret and snap open on entry, which moved the whole note.
public final class FrontmatterLayoutFragment: NSTextLayoutFragment {
    public var roundsTop = false
    public var roundsBottom = false
    public var fillColor: PlatformColor = MarkdownTheme.default.frontmatterCardBackground

    override public var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: 0, y: 0, width: cardWidth, height: layoutFragmentFrame.height)
        )
    }

    /// The card spans the text container, not the line: a fragment's frame
    /// is only as wide as its own text, which left the slices ragged.
    private var cardWidth: CGFloat {
        let container = textLayoutManager?.textContainer?.size.width ?? 0
        return container > 1 ? container : layoutFragmentFrame.width
    }

    override public func draw(at point: CGPoint, in context: CGContext) {
        let frame = layoutFragmentFrame
        // Slices overdraw 0.5pt vertically so adjacent rows show no seams.
        let rect = CGRect(
            x: point.x + 1, y: point.y - 0.5,
            width: max(cardWidth - 2, 0), height: frame.height + 1
        )
        if !rect.isEmpty {
            context.saveGState()
            context.addPath(CodeCardLayoutFragment.path(
                for: rect, radius: 8, top: roundsTop, bottom: roundsBottom
            ))
            context.setFillColor(fillColor.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// Live Preview styling for the frontmatter block: one set of metrics for
/// both caret states — only the colors change — so entering or leaving the
/// card cannot reflow the note. Attribute-only; characters are untouched,
/// and `MarkdownDocument.bodyUTF16Offset` still defines the block, so a
/// locked note gets the card over its frontmatter lines only and its
/// encrypted body is left alone.
public enum FrontmatterStyling {
    /// The frontmatter block's UTF-16 range, or nil when the note has none.
    public static func blockRange(in text: String) -> NSRange? {
        let length = MarkdownDocument(source: text).bodyUTF16Offset
        guard length > 0 else { return nil }
        return NSRange(location: 0, length: min(length, (text as NSString).length))
    }

    public static func apply(
        to storage: NSTextStorage,
        text: String,
        theme: MarkdownTheme,
        focused: Bool,
        clip: NSRange? = nil
    ) {
        guard let block = blockRange(in: text), block.length > 0 else { return }
        let ns = text as NSString
        // Clipped to the incremental update's window for the same reason as
        // TableStyling: the fold pass that would re-hide it is windowed.
        let bounds = clip.map { NSIntersectionRange($0, NSRange(location: 0, length: ns.length)) }
            ?? NSRange(location: 0, length: ns.length)
        func write(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            let target = NSIntersectionRange(range, bounds)
            guard target.length > 0 else { return }
            storage.addAttributes(attributes, range: target)
        }
        write(theme.frontmatterAttributes(focused: focused), block)
        var offset = block.location
        for line in splitLines(ns.substring(with: block)) {
            let length = line.utf16.count
            defer { offset += length + 1 }
            let lineRange = NSRange(
                location: offset, length: min(length, max(NSMaxRange(block) - offset, 0))
            )
            guard lineRange.length > 0, NSMaxRange(lineRange) <= ns.length else { continue }
            let content = strippingCarriageReturn(line)
            if content.trimmingCharacters(in: .whitespaces) == "---" {
                write(theme.frontmatterFenceAttributes(focused: focused), lineRange)
                continue
            }
            // `key:` reads as the property name; a YAML list item ("- x")
            // has no colon and stays body-styled.
            guard let colon = content.firstIndex(of: ":") else { continue }
            let keyLength = String(content[...colon]).utf16.count
            guard keyLength > 0, keyLength <= lineRange.length else { continue }
            write(
                theme.frontmatterKeyAttributes(focused: focused),
                NSRange(location: lineRange.location, length: keyLength)
            )
        }
    }
}

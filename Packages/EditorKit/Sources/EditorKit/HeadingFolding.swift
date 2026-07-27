import Foundation
import MarkdownKit

/// Fold math for heading-based collapsing: a fold hides everything after
/// the heading's paragraph up to the next heading of equal-or-higher
/// level (or end of document). Pure — display state lives in the editor.
public enum HeadingFolding {
    public struct HeadingInfo: Equatable, Sendable {
        public let range: NSRange
        public let level: Int
        public let title: String
        /// Stable-ish identity across edits elsewhere in the document.
        public var key: String {
            "\(level)|\(title)"
        }
    }

    public static func headings(in text: String, styled: [StyledRange]) -> [HeadingInfo] {
        let ns = text as NSString
        return styled.compactMap { item in
            guard case let .heading(level) = item.kind,
                  NSMaxRange(item.range) <= ns.length else { return nil }
            let raw = ns.substring(with: item.range)
            let title = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop { $0 == "#" }
                .trimmingCharacters(in: .whitespaces)
            return HeadingInfo(range: item.range, level: level, title: title)
        }
    }

    /// The range hidden when `heading` folds: from the end of its
    /// paragraph to the start of the next heading with level <= its own.
    public static func foldRange(
        for heading: HeadingInfo, in text: String, headings: [HeadingInfo]
    ) -> NSRange? {
        let ns = text as NSString
        let paragraph = ns.paragraphRange(for: heading.range)
        let start = NSMaxRange(paragraph)
        let end = headings
            .filter { $0.range.location > heading.range.location && $0.level <= heading.level }
            .map { ns.paragraphRange(for: $0.range).location }
            .min() ?? ns.length
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// All ranges to hide for the given folded keys.
    public static func foldRanges(
        foldedKeys: Set<String>, in text: String, styled: [StyledRange]
    ) -> [NSRange] {
        let all = headings(in: text, styled: styled)
        return all.compactMap { heading in
            guard foldedKeys.contains(heading.key) else { return nil }
            return foldRange(for: heading, in: text, headings: all)
        }
    }
}

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Draws the fold chevron in the left margin of heading paragraphs:
/// ▾ expanded, ▸ folded. The editor hit-tests margin clicks to toggle.
public final class HeadingFoldFragment: NSTextLayoutFragment {
    public var folded = false
    public var chevronColor: PlatformColor = .secondaryLabelCompat

    override public var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(
            CGRect(x: -14, y: 0, width: 14, height: layoutFragmentFrame.height)
        )
    }

    override public func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first else { return }
        let bounds = line.typographicBounds
        let midY = point.y + bounds.midY
        let x = point.x - 12
        context.saveGState()
        context.setFillColor(chevronColor.cgColor)
        context.beginPath()
        if folded {
            context.move(to: CGPoint(x: x, y: midY - 5))
            context.addLine(to: CGPoint(x: x + 7, y: midY))
            context.addLine(to: CGPoint(x: x, y: midY + 5))
        } else {
            context.move(to: CGPoint(x: x - 1, y: midY - 2))
            context.addLine(to: CGPoint(x: x + 7, y: midY - 2))
            context.addLine(to: CGPoint(x: x + 3, y: midY + 4))
        }
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }
}

extension PlatformColor {
    static var secondaryLabelCompat: PlatformColor {
        #if canImport(AppKit)
            .secondaryLabelColor
        #else
            .secondaryLabel
        #endif
    }
}

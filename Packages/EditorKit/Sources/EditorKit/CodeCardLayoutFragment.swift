import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Fenced-code presentation: each code paragraph draws its horizontal slice
/// of one full-width tinted card (top slice rounds the top corners, bottom
/// slice the bottom); the first slice also carries the language badge.
public final class CodeCardLayoutFragment: NSTextLayoutFragment {
    public var roundsTop = false
    public var roundsBottom = false
    public var badge: String?
    public var fillColor: PlatformColor = MarkdownTheme.default.surfaceBackground
    public var badgeColor: PlatformColor = MarkdownTheme.default.secondaryColor

    override public func draw(at point: CGPoint, in context: CGContext) {
        let frame = layoutFragmentFrame
        let radius: CGFloat = 8
        // Slices overdraw 0.5pt vertically so adjacent rows never show seams.
        let rect = CGRect(
            x: point.x + 1, y: point.y - 0.5,
            width: max(frame.width - 2, 0), height: frame.height + 1
        )
        if !rect.isEmpty {
            context.saveGState()
            context.addPath(Self.path(for: rect, radius: radius, top: roundsTop, bottom: roundsBottom))
            context.setFillColor(fillColor.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        super.draw(at: point, in: context)
        if let badge, !badge.isEmpty {
            drawBadge(badge, in: rect, context: context)
        }
    }

    private func drawBadge(_ text: String, in rect: CGRect, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: badgeColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let origin = CGPoint(x: rect.maxX - size.width - 10, y: rect.minY + 5)
        #if canImport(AppKit)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            string.draw(at: origin)
            NSGraphicsContext.current = previous
        #else
            UIGraphicsPushContext(context)
            string.draw(at: origin)
            UIGraphicsPopContext()
        #endif
    }

    /// Rounded rect with per-edge corner rounding (top/bottom slices of a
    /// card that spans several layout fragments).
    static func path(for rect: CGRect, radius: CGFloat, top: Bool, bottom: Bool) -> CGPath {
        let path = CGMutablePath()
        let topRadius = top ? radius : 0
        let bottomRadius = bottom ? radius : 0
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + topRadius, y: rect.minY), radius: topRadius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRadius), radius: topRadius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY), radius: bottomRadius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius), radius: bottomRadius
        )
        path.closeSubpath()
        return path
    }
}

/// One card region per fenced code block: the content lines between the
/// fences (which live-preview hides), plus the language for the badge.
public enum CodeCardRegions {
    public struct Region: Equatable, Sendable {
        public let range: NSRange
        public let language: String?
    }

    public static func regions(in text: String, styled: [StyledRange]) -> [Region] {
        let ns = text as NSString
        var found: [Region] = []
        for item in styled {
            guard case let .codeBlock(language) = item.kind,
                  NSMaxRange(item.range) <= ns.length else { continue }
            let content = ns.substring(with: item.range)
            guard content.hasPrefix("```") || content.hasPrefix("~~~") else { continue }
            var lines = MarkdownKit.splitLines(content)
            if lines.last == "" { lines.removeLast() } // trailing newline artifact
            guard lines.count > 1 else { continue }
            let firstLength = String(lines[0]).utf16.count + 1 // + newline
            var lastLength = 0
            let last = String(lines[lines.count - 1])
            if last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
                || last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("~~~") {
                lastLength = last.utf16.count + (content.hasSuffix("\n") ? 1 : 0)
            }
            let start = item.range.location + firstLength
            let length = item.range.length - firstLength - lastLength
            if length > 0 {
                found.append(Region(range: NSRange(location: start, length: length), language: language))
            }
        }
        return found
    }
}

import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Applies theme attributes to an NSTextStorage from one MarkdownStyler
/// parse. Attribute-only edits: never mutates characters, so calling this
/// from a text-change callback cannot recurse.
public enum MarkdownHighlighter {
    /// - Parameter hideMarkersOutside: Live Preview — syntax markers outside
    ///   this range (typically the cursor's paragraph) are rendered
    ///   near-invisible. Pass nil for source mode (all markers visible).
    /// - Parameter dimOutside: Focus mode — text outside this range (the
    ///   cursor's paragraph) recedes to the theme's dim color.
    /// Returns the styled ranges it computed so callers (the editor
    /// coordinators) can derive layout data without a second parse.
    @discardableResult
    public static func highlight(
        _ storage: NSTextStorage,
        theme: MarkdownTheme = .default,
        hideMarkersOutside: NSRange? = nil,
        dimOutside: NSRange? = nil
    ) -> [StyledRange] {
        let text = storage.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let styled = MarkdownStyler.styleRanges(in: text)

        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: fullRange)
        for item in styled {
            guard NSMaxRange(item.range) <= fullRange.length else { continue }
            let attributes = theme.attributes(for: item.kind)
            if !attributes.isEmpty {
                storage.addAttributes(attributes, range: item.range)
            }
        }
        // Standalone image lines reserve room below for the thumbnail the
        // layout fragment draws.
        for item in styled {
            guard case .image = item.kind, NSMaxRange(item.range) <= fullRange.length else { continue }
            let paragraph = (text as NSString).paragraphRange(for: item.range)
            guard ImageThumbnails.standaloneImageSource(
                (text as NSString).substring(with: paragraph)
            ) != nil else { continue }
            storage.addAttribute(.paragraphStyle, value: theme.imageParagraphStyle, range: paragraph)
        }
        for token in TaskCheckboxes.tokens(in: text, styled: styled)
            where NSMaxRange(token.range) <= fullRange.length {
            var attributes = theme.checkboxTokenAttributes(checked: token.checked)
            attributes[.link] = Self.toggleURL(at: token.range.location)
            storage.addAttributes(attributes, range: token.range)
        }
        if let focus = dimOutside {
            let clamped = NSIntersectionRange(focus, fullRange)
            let head = NSRange(location: 0, length: clamped.location)
            let tail = NSRange(
                location: NSMaxRange(clamped),
                length: fullRange.length - NSMaxRange(clamped)
            )
            for region in [head, tail] where region.length > 0 {
                storage.addAttribute(.foregroundColor, value: theme.focusDimColor, range: region)
            }
        }
        // Marker hiding comes last so its .clear color survives focus dim.
        if let visible = hideMarkersOutside {
            // Tables: the drawn grid carries the content while the cursor is
            // elsewhere; raw pipes come back the moment the cursor enters.
            for item in styled
                where item.kind == .table
                && NSIntersectionRange(item.range, visible).length == 0
                && NSMaxRange(item.range) <= fullRange.length {
                storage.addAttribute(
                    .foregroundColor, value: PlatformColor.clear, range: item.range
                )
            }
            // Thematic breaks: the drawn divider carries the meaning, so the
            // dashes go clear at FULL size (0.01pt would collapse the row).
            for item in styled
                where item.kind == .thematicBreak
                && NSIntersectionRange(item.range, visible).length == 0
                && NSMaxRange(item.range) <= fullRange.length {
                storage.addAttribute(
                    .foregroundColor, value: PlatformColor.clear, range: item.range
                )
            }
            for marker in SyntaxMarkers.markerRanges(in: text, styled: styled)
                where NSIntersectionRange(marker, visible).length == 0
                && NSMaxRange(marker) <= fullRange.length {
                storage.addAttributes(theme.hiddenMarkerAttributes, range: marker)
            }
        }
        storage.endEditing()
        return styled
    }

    /// Custom scheme the editor intercepts to flip a checkbox token.
    public static func toggleURL(at utf16Offset: Int) -> URL {
        URL(string: "notetaker-task://toggle/\(utf16Offset)")!
    }

    /// The token offset if `url` is a checkbox-toggle link.
    public static func toggleOffset(from url: URL) -> Int? {
        guard url.scheme == "notetaker-task", url.host() == "toggle" else { return nil }
        return Int(url.lastPathComponent)
    }
}

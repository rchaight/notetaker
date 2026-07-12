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
    public static func highlight(
        _ storage: NSTextStorage,
        theme: MarkdownTheme = .default,
        hideMarkersOutside: NSRange? = nil,
        dimOutside: NSRange? = nil
    ) {
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
            for marker in SyntaxMarkers.markerRanges(in: text, styled: styled)
                where NSIntersectionRange(marker, visible).length == 0
                && NSMaxRange(marker) <= fullRange.length {
                storage.addAttributes(theme.hiddenMarkerAttributes, range: marker)
            }
        }
        storage.endEditing()
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

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
    public static func highlight(
        _ storage: NSTextStorage,
        theme: MarkdownTheme = .default,
        hideMarkersOutside: NSRange? = nil
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
        if let visible = hideMarkersOutside {
            for marker in SyntaxMarkers.markerRanges(in: text, styled: styled)
                where NSIntersectionRange(marker, visible).length == 0
                && NSMaxRange(marker) <= fullRange.length {
                storage.addAttributes(theme.hiddenMarkerAttributes, range: marker)
            }
        }
        storage.endEditing()
    }
}

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
    public static func highlight(_ storage: NSTextStorage, theme: MarkdownTheme = .default) {
        let text = storage.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: fullRange)
        for styled in MarkdownStyler.styleRanges(in: text) {
            guard NSMaxRange(styled.range) <= fullRange.length else { continue }
            let attributes = theme.attributes(for: styled.kind)
            if !attributes.isEmpty {
                storage.addAttributes(attributes, range: styled.range)
            }
        }
        storage.endEditing()
    }
}

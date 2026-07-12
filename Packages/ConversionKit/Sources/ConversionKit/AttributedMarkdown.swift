import Foundation

#if canImport(AppKit)
    import AppKit

    typealias ConversionFont = NSFont
#else
    import UIKit

    typealias ConversionFont = UIFont
#endif

/// NSAttributedString → markdown, preserving headings (by font size) and
/// bold/italic runs. Good enough for RTF/HTML imports; Docling handles the
/// hard layouts.
public enum AttributedMarkdown {
    public static func markdown(from attributed: NSAttributedString, bodyPointSize: CGFloat = 12) -> String {
        var paragraphs: [String] = []
        let text = attributed.string as NSString

        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length), options: .byParagraphs
        ) { _, paragraphRange, _, _ in
            var pieces: [String] = []
            var maxSize: CGFloat = 0

            attributed.enumerateAttributes(in: paragraphRange) { attributes, runRange, _ in
                var run = text.substring(with: runRange)
                guard !run.isEmpty else { return }
                if let font = attributes[.font] as? ConversionFont {
                    maxSize = max(maxSize, font.pointSize)
                    let traits = font.fontDescriptor.symbolicTraits
                    #if canImport(AppKit)
                        let isBold = traits.contains(.bold)
                        let isItalic = traits.contains(.italic)
                    #else
                        let isBold = traits.contains(.traitBold)
                        let isItalic = traits.contains(.traitItalic)
                    #endif
                    let trimmed = run.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        if isBold, isItalic {
                            run = run.replacingOccurrences(of: trimmed, with: "***\(trimmed)***")
                        } else if isBold {
                            run = run.replacingOccurrences(of: trimmed, with: "**\(trimmed)**")
                        } else if isItalic {
                            run = run.replacingOccurrences(of: trimmed, with: "*\(trimmed)*")
                        }
                    }
                }
                pieces.append(run)
            }

            var paragraph = pieces.joined().trimmingCharacters(in: .whitespaces)
            guard !paragraph.isEmpty else { return }

            // Whole-paragraph size promotion → heading. A bold-only short
            // paragraph reads as a heading too (common in RTF exports).
            let ratio = maxSize / bodyPointSize
            if ratio >= 1.8 {
                paragraph = "# " + strippedEmphasis(paragraph)
            } else if ratio >= 1.4 {
                paragraph = "## " + strippedEmphasis(paragraph)
            } else if ratio >= 1.15 {
                paragraph = "### " + strippedEmphasis(paragraph)
            }
            paragraphs.append(paragraph)
        }
        return paragraphs.joined(separator: "\n\n") + (paragraphs.isEmpty ? "" : "\n")
    }

    private static func strippedEmphasis(_ text: String) -> String {
        text.replacingOccurrences(of: "***", with: "")
            .replacingOccurrences(of: "**", with: "")
    }
}

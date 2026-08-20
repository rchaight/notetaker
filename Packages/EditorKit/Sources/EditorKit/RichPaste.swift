import Foundation

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// One image (or, in principle, other attachment) offered up by a paste
/// or drop for the app to copy into the vault's `Attachments/` folder.
/// `NotesModel.attachImage` is the app-side consumer. The editor's
/// `importAttachments` closure returns `[String]` index-aligned with the
/// `[AttachmentDrop]` it was given — an empty string marks a drop that
/// failed to import, so a partial failure never mis-pairs a name with the
/// wrong path.
public struct AttachmentDrop: Sendable {
    public enum Source: Sendable {
        case fileURL(URL)
        case data(Data)
    }

    public let source: Source
    public let suggestedName: String

    public init(source: Source, suggestedName: String) {
        self.source = source
        self.suggestedName = suggestedName
    }
}

/// Converts rich paste content into the editor's plain-markdown source and
/// makes the paste-time judgment calls (is this already markdown? does a
/// URL-over-selection become a link?). Pure — the HTML/RTF → NSAttributedString
/// import happens at the call site (`MarkdownTextView`/`MarkdownUITextView`)
/// with the standard system importers; this type never touches a pasteboard.
public enum RichPaste {
    // MARK: - NSAttributedString -> markdown

    /// Walks paragraphs and runs, emitting CommonMark. Unknown styling
    /// degrades to plain text — text content is never dropped, only the
    /// styling that can't be mapped to a markdown construct.
    public static func markdown(fromAttributed attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let bodySize = dominantFontSize(in: attributed, fallback: 13)
        var blocks: [Block] = []
        for range in paragraphRanges(in: attributed.string) {
            guard range.length > 0 else {
                blocks.append(Block(kind: .paragraph, text: ""))
                continue
            }
            blocks.append(block(for: attributed.attributedSubstring(from: range), bodySize: bodySize))
        }
        // A trailing "\n" in the source produces one stray empty paragraph
        // at the end — drop it so converted text doesn't end in a blank line.
        if blocks.count > 1, let last = blocks.last, last.text.isEmpty {
            blocks.removeLast()
        }
        return render(blocks)
    }

    /// Heuristic used to prefer the PLAIN pasteboard string over an
    /// HTML/RTF conversion when the source already looks like markdown
    /// (pasting from another markdown editor should paste verbatim).
    public static func isProbablyMarkdown(_ plain: String) -> Bool {
        let lines = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        var strongSignals = 0
        var weakSignals = 0
        var fences = 0
        for line in lines {
            if looksLikeFence(line) {
                fences += 1
                continue
            }
            if looksLikePipeTableRow(line) {
                strongSignals += 1
            }
            if containsMarkdownLink(line) {
                strongSignals += 1
            }
            if looksLikeHeading(line) {
                weakSignals += 1
            }
            if looksLikeBullet(line) {
                weakSignals += 1
            }
            if looksLikeOrderedItem(line) {
                weakSignals += 1
            }
        }
        if fences >= 2 {
            strongSignals += 1
        }
        return strongSignals > 0 || weakSignals >= 2
    }

    /// `[selection](url)` when `pasted` is a single http(s) URL, the
    /// selection is non-empty, and the selection isn't itself a URL
    /// (pasting a URL over a URL replaces it instead of wrapping it).
    public static func linkWrapping(selection: String, pasted: String) -> String? {
        let trimmedPasted = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty,
              isLoneHTTPURL(trimmedPasted),
              !isLoneHTTPURL(selection.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return "[\(selection)](\(trimmedPasted))"
    }

    // MARK: - isProbablyMarkdown line heuristics

    private static func looksLikeHeading(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return false }
        let rest = line.dropFirst(hashes.count)
        return rest.hasPrefix(" ") && !rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func looksLikeBullet(_ line: String) -> Bool {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return !line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    private static func looksLikeOrderedItem(_ line: String) -> Bool {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        return rest.dropFirst().hasPrefix(" ")
    }

    private static func looksLikeFence(_ line: String) -> Bool {
        line.hasPrefix("```")
    }

    private static func looksLikePipeTableRow(_ line: String) -> Bool {
        guard line.filter({ $0 == "|" }).count >= 2 else { return false }
        let withoutPipes = line.replacingOccurrences(of: "|", with: "")
        let isSeparatorRow = !withoutPipes.isEmpty && withoutPipes.allSatisfy { " -:".contains($0) }
        return isSeparatorRow || line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    private static func containsMarkdownLink(_ line: String) -> Bool {
        guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return false }
        let afterClose = line.index(after: close)
        guard afterClose < line.endIndex, line[afterClose] == "(" else { return false }
        guard let closeParen = line[afterClose...].firstIndex(of: ")") else { return false }
        return closeParen > line.index(after: afterClose)
    }

    private static func isLoneHTTPURL(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), url.host != nil,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        return true
    }

    // MARK: - Block model

    private struct Block {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case bulletItem(level: Int)
            case numberedItem(level: Int)
            case blockquote
            case codeLine
        }

        var kind: Kind
        var text: String
    }

    private static func paragraphRanges(in string: String) -> [NSRange] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        var ranges: [NSRange] = []
        ns
            .enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                 options: .byParagraphs) { _, substringRange, _, _ in
                ranges.append(substringRange)
            }
        return ranges
    }

    private static func block(for paragraph: NSAttributedString, bodySize: CGFloat) -> Block {
        let plain = paragraph.string
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Block(kind: .paragraph, text: "")
        }

        if isFullyMonospaced(paragraph) {
            return Block(kind: .codeLine, text: plain.trimmingCharacters(in: .whitespaces))
        }

        let paragraphStyle = paragraph.attributes(at: 0, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle

        if let lists = paragraphStyle?.textLists, !lists.isEmpty {
            let level = max(lists.count - 1, 0)
            let ordered = lists.last?.markerFormat.rawValue.lowercased().contains("decimal") ?? false
            return Block(
                kind: ordered ? .numberedItem(level: level) : .bulletItem(level: level),
                text: inlineMarkdown(for: paragraph)
            )
        }

        if let marker = leadingListMarker(in: plain) {
            let stripped = paragraph.attributedSubstring(
                from: NSRange(location: marker.length, length: paragraph.length - marker.length)
            )
            return Block(
                kind: marker.ordered ? .numberedItem(level: 0) : .bulletItem(level: 0),
                text: inlineMarkdown(for: stripped)
            )
        }

        if let level = headingLevel(for: paragraph, bodySize: bodySize) {
            return Block(kind: .heading(level), text: inlineMarkdown(for: paragraph))
        }

        // Indented paragraphs (HTML <blockquote> imports with a wide,
        // uniform head indent) read as blockquotes; a small default
        // indent some importers set doesn't cross this threshold.
        if let style = paragraphStyle, style.headIndent >= 24, style.firstLineHeadIndent >= 24 {
            return Block(kind: .blockquote, text: inlineMarkdown(for: paragraph))
        }

        return Block(kind: .paragraph, text: inlineMarkdown(for: paragraph))
    }

    private static func render(_ blocks: [Block]) -> String {
        var output: [String] = []
        var index = 0
        while index < blocks.count {
            switch blocks[index].kind {
            case .codeLine:
                var lines: [String] = []
                while index < blocks.count, case .codeLine = blocks[index].kind {
                    lines.append(blocks[index].text)
                    index += 1
                }
                output.append("```\n" + lines.joined(separator: "\n") + "\n```")
            case .bulletItem:
                var lines: [String] = []
                while index < blocks.count, case let .bulletItem(level) = blocks[index].kind {
                    lines.append(String(repeating: "  ", count: level) + "- " + blocks[index].text)
                    index += 1
                }
                output.append(lines.joined(separator: "\n"))
            case .numberedItem:
                var lines: [String] = []
                var counters: [Int: Int] = [:]
                while index < blocks.count, case let .numberedItem(level) = blocks[index].kind {
                    counters[level, default: 0] += 1
                    lines.append(String(repeating: "  ", count: level) + "\(counters[level]!). " + blocks[index].text)
                    index += 1
                }
                output.append(lines.joined(separator: "\n"))
            case .blockquote:
                var lines: [String] = []
                while index < blocks.count, case .blockquote = blocks[index].kind {
                    lines.append("> " + blocks[index].text)
                    index += 1
                }
                output.append(lines.joined(separator: "\n"))
            case let .heading(level):
                output.append(String(repeating: "#", count: level) + " " + blocks[index].text)
                index += 1
            case .paragraph:
                if !blocks[index].text.isEmpty {
                    output.append(blocks[index].text)
                }
                index += 1
            }
        }
        return output.joined(separator: "\n\n")
    }

    // MARK: - Leading marker fallback (RTF sources that don't carry NSTextList)

    private struct LeadingMarker {
        let length: Int
        let ordered: Bool
    }

    /// Only recognizes glyphs an importer would use for a *rendered*
    /// bullet ("•", "◦", …) — a paragraph that already starts with a
    /// literal "-"/"*"/"+ " reads fine as-is once emitted as markdown, so
    /// it's left to the plain-paragraph path.
    private static func leadingListMarker(in line: String) -> LeadingMarker? {
        let bulletGlyphs: Set<Character> = ["•", "◦", "▪", "‣"]
        if let first = line.first, bulletGlyphs.contains(first) {
            let rest = line.dropFirst()
            if let separator = rest.first, separator == " " || separator == "\t" {
                return LeadingMarker(length: (String(line.prefix(2)) as NSString).length, ordered: false)
            }
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard let marker = afterDigits.first, marker == "." || marker == ")" else { return nil }
        let afterMarker = afterDigits.dropFirst()
        guard afterMarker.first == " " else { return nil }
        let markerString = digits + String(marker) + " "
        return LeadingMarker(length: (String(markerString) as NSString).length, ordered: true)
    }

    // MARK: - Inline run conversion

    private struct RunStyle: Equatable {
        var bold = false
        var italic = false
        var strikethrough = false
        var code = false
        var link: URL?
    }

    private static func inlineMarkdown(for attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        var runs: [(text: String, style: RunStyle)] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attrs, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            var style = RunStyle()
            if let font = attrs[.font] as? PlatformFont {
                style.bold = isBold(font)
                style.italic = isItalic(font)
                style.code = isMonospaced(font)
            }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 {
                style.strikethrough = true
            }
            if let url = attrs[.link] as? URL {
                style.link = url
            } else if let raw = attrs[.link] as? String, let url = URL(string: raw) {
                style.link = url
            }
            if !runs.isEmpty, runs[runs.count - 1].style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append((text, style))
            }
        }
        return runs.map { wrap($0.text, style: $0.style) }.joined()
    }

    private static func wrap(_ text: String, style: RunStyle) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        if style.code {
            return "`\(text)`"
        }
        var result = text
        if style.bold, style.italic {
            result = "***\(result)***"
        } else if style.bold {
            result = "**\(result)**"
        } else if style.italic {
            result = "*\(result)*"
        }
        if style.strikethrough {
            result = "~~\(result)~~"
        }
        if let link = style.link {
            result = "[\(result)](\(link.absoluteString))"
        }
        return result
    }

    // MARK: - Font inspection

    private static func isFullyMonospaced(_ paragraph: NSAttributedString) -> Bool {
        guard paragraph.length > 0 else { return false }
        var sawContent = false
        var allMono = true
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, range, stop in
            let substring = (paragraph.string as NSString).substring(with: range)
            guard !substring.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            sawContent = true
            guard let font = value as? PlatformFont, isMonospaced(font) else {
                allMono = false
                stop.pointee = true
                return
            }
        }
        return sawContent && allMono
    }

    private static func dominantFontSize(in attributed: NSAttributedString, fallback: CGFloat = 0) -> CGFloat {
        guard attributed.length > 0 else { return fallback }
        var totals: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? PlatformFont else { return }
            totals[font.pointSize, default: 0] += range.length
        }
        return totals.max(by: { $0.value < $1.value })?.key ?? fallback
    }

    private static func headingLevel(for paragraph: NSAttributedString, bodySize: CGFloat) -> Int? {
        guard bodySize > 0 else { return nil }
        let size = dominantFontSize(in: paragraph)
        guard size > 0 else { return nil }
        let ratio = size / bodySize
        if ratio >= 1.55 {
            return 1
        }
        if ratio >= 1.35 {
            return 2
        }
        if ratio >= 1.2 {
            return 3
        }
        if ratio >= 1.08 {
            return 4
        }
        return nil
    }

    #if canImport(AppKit)
        private static func isBold(_ font: PlatformFont) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.bold)
        }

        private static func isItalic(_ font: PlatformFont) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.italic)
        }

        private static func isMonospaced(_ font: PlatformFont) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
    #else
        private static func isBold(_ font: PlatformFont) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.traitBold)
        }

        private static func isItalic(_ font: PlatformFont) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        }

        private static func isMonospaced(_ font: PlatformFont) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        }
    #endif
}

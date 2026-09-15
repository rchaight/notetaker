import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// What Live Preview reveals around the caret, Typora-style: block syntax
/// (heading hashes, blockquote prefixes, code fences) reveals for the
/// caret's line, while inline syntax (`**`, `` ` ``, `~~`, `==`, `[[ ]]`,
/// `[text](url)`) reveals only for the span the selection contains or
/// touches. A caret in plain text between two bold spans reveals neither.
///
/// The block-level renderings that also swap with the caret's line —
/// frontmatter, tables, thematic breaks — key off `blockRange`.
public struct RevealScope: Equatable, Sendable {
    /// The selection that opens the scope; length 0 is a plain caret.
    public let selection: NSRange
    /// The paragraph(s) the selection touches.
    public let blockRange: NSRange

    public init(selection: NSRange, blockRange: NSRange) {
        self.selection = selection
        self.blockRange = blockRange
    }

    /// The scope for `selection` in `text`: the selection itself plus the
    /// paragraph(s) it touches.
    public static func at(_ selection: NSRange, in text: String) -> RevealScope {
        let ns = text as NSString
        let location = min(max(selection.location, 0), ns.length)
        let clamped = NSRange(
            location: location,
            length: min(max(selection.length, 0), ns.length - location)
        )
        return RevealScope(selection: clamped, blockRange: ns.paragraphRange(for: clamped))
    }

    /// Block syntax reveals when it sits on a line the selection touches.
    public func revealsBlock(_ range: NSRange) -> Bool {
        NSIntersectionRange(range, blockRange).length > 0
    }

    /// Inline syntax reveals only for a span the selection contains or
    /// touches — either delimiter counts, so a caret parked against a
    /// bold span opens it, but a caret in the plain text between two
    /// spans opens neither.
    public func revealsSpan(_ span: NSRange) -> Bool {
        NSMaxRange(span) >= selection.location && span.location <= NSMaxRange(selection)
    }

    /// Whether this scope reveals `marker`, given the group that owns it.
    public func reveals(_ marker: NSRange, of group: SyntaxMarkers.MarkerGroup) -> Bool {
        group.isBlockLevel ? revealsBlock(marker) : revealsSpan(group.span)
    }

    /// The spans of `groups` whose markers this scope reveals — the shape
    /// of the reveal, for tests and debugging.
    public func revealedSpans(in groups: [SyntaxMarkers.MarkerGroup]) -> [NSRange] {
        groups.filter { group in
            group.markers.contains { reveals($0, of: group) }
        }.map(\.span)
    }
}

/// Applies theme attributes to an NSTextStorage from one MarkdownStyler
/// parse. Attribute-only edits: never mutates characters, so calling this
/// from a text-change callback cannot recurse.
public enum MarkdownHighlighter {
    /// - Parameter styled: a parse of `storage`'s text the caller already
    ///   has (the editor's coordinator caches one); nil parses here.
    /// - Parameter groups: marker groups for that parse; nil derives them.
    /// - Parameter reveal: Live Preview — syntax markers outside this scope
    ///   are rendered near-invisible. Pass nil for source mode (all markers
    ///   visible).
    /// - Parameter dimOutside: Focus mode — text outside this range (the
    ///   cursor's paragraph) recedes to the theme's dim color.
    /// Returns the styled ranges it used so callers (the editor
    /// coordinators) can derive layout data without a second parse.
    @discardableResult
    public static func highlight(
        _ storage: NSTextStorage,
        theme: MarkdownTheme = .default,
        styled: [StyledRange]? = nil,
        groups: [SyntaxMarkers.MarkerGroup]? = nil,
        reveal: RevealScope? = nil,
        dimOutside: NSRange? = nil,
        foldRanges: [NSRange] = []
    ) -> [StyledRange] {
        let text = storage.string
        let parsed = styled ?? MarkdownStyler.styleRanges(in: text)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        storage.beginEditing()
        applyAttributes(
            storage,
            text: text,
            theme: theme,
            styled: parsed,
            groups: groups ?? SyntaxMarkers.markerGroups(in: text, styled: parsed),
            reveal: reveal,
            dimOutside: dimOutside,
            foldRanges: foldRanges,
            window: fullRange
        )
        storage.endEditing()
        return parsed
    }

    /// Moves the reveal from one scope to another without re-parsing: the
    /// parse cannot change when only the caret moved. Only the paragraphs
    /// whose appearance actually flips are re-styled, so a caret move costs
    /// a line or two of attribute writes instead of a whole-note pass.
    ///
    /// `styled` must be the parse the storage's current text produced (the
    /// editor coordinator caches it and re-parses on every text change),
    /// and `dimOutside` must be the SAME focus region both scopes were
    /// styled with — focus mode moves its dim with the caret, so it does a
    /// full restyle instead of calling this.
    ///
    /// Returns true when something was re-styled.
    @discardableResult
    public static func updateReveal(
        _ storage: NSTextStorage,
        theme: MarkdownTheme = .default,
        styled: [StyledRange],
        groups: [SyntaxMarkers.MarkerGroup]? = nil,
        from old: RevealScope?,
        to new: RevealScope?,
        dimOutside: NSRange? = nil,
        foldRanges: [NSRange] = []
    ) -> Bool {
        let text = storage.string
        let markerGroups = groups ?? SyntaxMarkers.markerGroups(in: text, styled: styled)
        let changed = revealDelta(
            in: text, styled: styled, groups: markerGroups, from: old, to: new
        )
        let windows = paragraphWindows(for: changed, in: text as NSString)
        guard !windows.isEmpty else { return false }

        storage.beginEditing()
        for window in windows {
            applyAttributes(
                storage,
                text: text,
                theme: theme,
                styled: styled,
                groups: markerGroups,
                reveal: new,
                dimOutside: dimOutside,
                foldRanges: foldRanges,
                window: window
            )
        }
        storage.endEditing()
        return true
    }

    /// The ranges whose appearance differs between two reveal scopes for one
    /// parse: markers that flip hidden/visible, plus the block renderings
    /// (tables, thematic breaks, frontmatter) keyed to the caret's line. An
    /// empty result means the caret move cannot change a single pixel.
    public static func revealDelta(
        in text: String,
        styled: [StyledRange],
        groups: [SyntaxMarkers.MarkerGroup]? = nil,
        from old: RevealScope?,
        to new: RevealScope?
    ) -> [NSRange] {
        let length = (text as NSString).length
        var changed: [NSRange] = []
        /// A nil scope is source mode: everything is revealed.
        func flipped(_ revealed: (RevealScope) -> Bool) -> Bool {
            (old.map(revealed) ?? true) != (new.map(revealed) ?? true)
        }
        for group in groups ?? SyntaxMarkers.markerGroups(in: text, styled: styled) {
            for marker in group.markers where NSMaxRange(marker) <= length {
                if flipped({ $0.reveals(marker, of: group) }) {
                    changed.append(marker)
                }
            }
        }
        for item in styled
            where (item.kind == .table || item.kind == .thematicBreak)
            && NSMaxRange(item.range) <= length {
            if flipped({ $0.revealsBlock(item.range) }) {
                changed.append(item.range)
            }
        }
        let frontmatterLength = MarkdownDocument(source: text).bodyUTF16Offset
        if frontmatterLength > 0 {
            let block = NSRange(location: 0, length: min(frontmatterLength, length))
            if flipped({ $0.revealsBlock(block) }) {
                changed.append(block)
            }
        }
        return changed
    }

    /// Paragraph-aligned, coalesced windows covering `ranges`. Attribute
    /// re-application has to be paragraph-aligned because paragraph styles
    /// (list indents, image rows) are per-paragraph attributes.
    private static func paragraphWindows(for ranges: [NSRange], in ns: NSString) -> [NSRange] {
        var expanded: [NSRange] = []
        for range in ranges where range.location >= 0 && range.location <= ns.length {
            let clamped = NSRange(
                location: range.location,
                length: min(max(range.length, 0), ns.length - range.location)
            )
            expanded.append(ns.paragraphRange(for: clamped))
        }
        guard !expanded.isEmpty else { return [] }
        expanded.sort { $0.location < $1.location }
        var merged = [expanded[0]]
        for range in expanded.dropFirst() {
            let last = merged[merged.count - 1]
            if range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged.filter { $0.length > 0 }
    }

    /// The one attribute pipeline, limited to `window`. `highlight` runs it
    /// over the whole storage; `updateReveal` runs it over the paragraphs
    /// whose reveal changed — same order, same values, so the result is
    /// identical to a full pass at the new scope.
    private static func applyAttributes(
        _ storage: NSTextStorage,
        text: String,
        theme: MarkdownTheme,
        styled: [StyledRange],
        groups: [SyntaxMarkers.MarkerGroup],
        reveal: RevealScope?,
        dimOutside: NSRange?,
        foldRanges: [NSRange],
        window: NSRange
    ) {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let clip = NSIntersectionRange(window, fullRange)
        guard clip.length > 0 else { return }
        /// Every write is bounds-guarded (styled ranges can outlive the text
        /// they came from) and clipped to the window.
        func write(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            guard !attributes.isEmpty, range.location >= 0, NSMaxRange(range) <= fullRange.length
            else { return }
            let target = NSIntersectionRange(range, clip)
            guard target.length > 0 else { return }
            storage.addAttributes(attributes, range: target)
        }

        storage.setAttributes(theme.baseAttributes, range: clip)
        for item in styled {
            write(theme.attributes(for: item.kind), item.range)
        }
        // Nested list/task lines get amplified display indentation: 2
        // source spaces = one visual level.
        Self.applyListIndents(text: text, theme: theme, write: write)
        // Standalone image lines reserve room below for the thumbnail the
        // layout fragment draws.
        for item in styled {
            guard case .image = item.kind, NSMaxRange(item.range) <= fullRange.length else { continue }
            let paragraph = ns.paragraphRange(for: item.range)
            guard ImageThumbnails.standaloneImageSource(
                ns.substring(with: paragraph)
            ) != nil else { continue }
            write([.paragraphStyle: theme.imageParagraphStyle], paragraph)
        }
        for token in TaskCheckboxes.tokens(in: text, styled: styled) {
            var attributes = theme.checkboxTokenAttributes(checked: token.checked)
            attributes[.link] = Self.toggleURL(at: token.range.location)
            write(attributes, token.range)
        }
        if let focus = dimOutside {
            let clamped = NSIntersectionRange(focus, fullRange)
            let head = NSRange(location: 0, length: clamped.location)
            let tail = NSRange(
                location: NSMaxRange(clamped),
                length: fullRange.length - NSMaxRange(clamped)
            )
            for region in [head, tail] where region.length > 0 {
                write([.foregroundColor: theme.focusDimColor], region)
            }
        }
        // Marker hiding comes last so its .clear color survives focus dim.
        if let reveal {
            // Frontmatter is metadata, not prose: collapse the whole block
            // off-cursor (it also stops reading as markdown — its closing
            // "---" was rendering as a divider). Cursor inside reveals it.
            let frontmatterLength = MarkdownDocument(source: text).bodyUTF16Offset
            if frontmatterLength > 0 {
                let block = NSRange(location: 0, length: min(frontmatterLength, fullRange.length))
                if !reveal.revealsBlock(block) {
                    write(theme.hiddenMarkerAttributes, block)
                }
            }
            // Tables: the drawn grid carries the content while the cursor is
            // elsewhere; raw pipes come back the moment the cursor enters.
            for item in styled
                where item.kind == .table
                && !reveal.revealsBlock(item.range)
                && NSMaxRange(item.range) <= fullRange.length {
                write([.foregroundColor: PlatformColor.clear], item.range)
            }
            // Thematic breaks: the drawn divider carries the meaning, so the
            // dashes go clear at FULL size (0.01pt would collapse the row).
            for item in styled
                where item.kind == .thematicBreak
                && !reveal.revealsBlock(item.range)
                && NSMaxRange(item.range) <= fullRange.length {
                write([.foregroundColor: PlatformColor.clear], item.range)
            }
            for group in groups {
                for marker in group.markers where !reveal.reveals(marker, of: group) {
                    write(theme.hiddenMarkerAttributes, marker)
                }
            }
        }
        // Heading folds hide whole sections (hair-height, like markers) —
        // applied last so nothing re-reveals them.
        for fold in foldRanges {
            write(theme.hiddenMarkerAttributes, fold)
        }
    }

    private static let listLineRegex = try? NSRegularExpression(
        pattern: "^( *)(?:[-*+]|[0-9]+[.)]) ",
        options: [.anchorsMatchLines]
    )

    static func applyListIndents(
        text: String,
        theme: MarkdownTheme,
        write: ([NSAttributedString.Key: Any], NSRange) -> Void
    ) {
        guard let regex = listLineRegex else { return }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let level = match.range(at: 1).length / 2
            guard level > 0 else { continue }
            write([.paragraphStyle: theme.listIndentStyle(level: level)], ns.paragraphRange(for: match.range))
        }
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

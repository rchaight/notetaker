import Foundation
import MarkdownKit
import TaskEngine

/// The ONE oracle for "this span is markup, not prose".
///
/// A markdown note is mostly English, but the parts that aren't — fenced
/// code, YAML frontmatter, URLs, `[[wikilinks]]`, `#tags`, `@handles` and
/// the inline task vocabulary (`>friday !p1 ^ship ✅2026-07-14`) — are
/// exactly the parts a spell or grammar checker mangles: every identifier
/// becomes a "misspelling", and with autocorrect on, `#Amber1` silently
/// turns into something else. This computes those spans once so every
/// proofing surface skips the same text:
///
/// - the editor's system-checker filter (`didCheckTextIn`) drops results
///   that land inside them,
/// - Writing Tools is handed them as ignored ranges,
/// - an external provider marks them as markup rather than sending them
///   for analysis.
///
/// Pure text math on a parse the caller already has — no I/O, no state, so
/// it is safe to call from the editor's styling path.
public enum ProofingExclusions {
    /// The spans of `text` that must not be proofread, coalesced and
    /// sorted. `styled` must be `MarkdownStyler.styleRanges(in: text)` for
    /// this exact text (the editor coordinator caches one per parse);
    /// ranges are full-document UTF-16, the same coordinates TextKit uses.
    public static func ranges(in text: String, styled: [StyledRange]) -> [NSRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return [] }
        var found: [NSRange] = []
        func add(_ range: NSRange) {
            let clipped = NSIntersectionRange(range, full)
            if clipped.length > 0 {
                found.append(clipped)
            }
        }

        // Frontmatter is machine-written YAML keys and dates — never prose.
        // `bodyUTF16Offset` is 0 when the note has no frontmatter block.
        add(NSRange(location: 0, length: MarkdownDocument(source: text).bodyUTF16Offset))

        for item in styled {
            switch item.kind {
            // Code is literal by definition; images, wikilinks and the
            // chip tokens are addresses and identifiers.
            case .inlineCode, .codeBlock, .image, .wikilink, .tag, .mention, .kindToken:
                add(item.range)
            default:
                continue
            }
        }

        // Links: the LABEL is prose and stays checkable — only the
        // destination goes. `SyntaxMarkers` already knows where a link's
        // `](destination)` starts, so the geometry lives in one place; its
        // trailing marker IS the destination plus its punctuation.
        var inlineLinks = Set<NSRange>()
        for group in SyntaxMarkers.markerGroups(in: text, styled: styled) {
            guard case .link = group.kind,
                  let destination = group.markers.max(by: { $0.location < $1.location })
            else { continue }
            inlineLinks.insert(group.span)
            add(destination)
        }
        for item in styled {
            guard case .link = item.kind, !inlineLinks.contains(item.range) else { continue }
            // No `[label](destination)` shape: an autolink or a
            // reference-style link, where the whole span is address.
            add(item.range)
        }

        // Bare `https://…` in prose. CommonMark leaves these as plain
        // text, so no styled range covers them.
        for regex in [bareURLRegex, angleAutolinkRegex].compactMap(\.self) {
            for match in regex.matches(in: text, range: full) {
                add(match.range)
            }
        }

        // Task lines: the inline token vocabulary, located by TaskEngine's
        // parser (never re-regexed here). Tokens live on the checkbox's own
        // line; a wrapped continuation line is prose.
        for token in TaskCheckboxes.tokens(in: text, styled: styled) {
            let line = ns.lineRange(for: token.range)
            add(token.range)
            for range in TaskTokenParser.tokenRanges(in: ns.substring(with: line)) {
                add(NSRange(location: line.location + range.location, length: range.length))
            }
        }

        return coalesced(found)
    }

    /// The ignored ranges for `textView(_:writingToolsIgnoredRangesInEnclosingRange:)`.
    ///
    /// Coordinate space: the UIKit header for the same delegate method
    /// documents the return value as "ranges in the attributed substring
    /// of the textView storage with the enclosing range" — i.e. relative
    /// to `enclosing.location`, not absolute. AppKit's declaration carries
    /// no comment, so the UIKit wording is the contract both honor. When
    /// Writing Tools passes the whole document (`location == 0`, the
    /// common case) the two readings coincide.
    public static func writingToolsIgnoredRanges(
        in text: String, styled: [StyledRange], enclosing: NSRange
    ) -> [NSRange] {
        guard enclosing.length > 0 else { return [] }
        return ranges(in: text, styled: styled).compactMap { range in
            let clipped = NSIntersectionRange(range, enclosing)
            guard clipped.length > 0 else { return nil }
            return NSRange(location: clipped.location - enclosing.location, length: clipped.length)
        }
    }

    /// The check results to KEEP, given `exclusions` — what the editor's
    /// `didCheckTextIn` delegate method returns.
    ///
    /// `.orthography` is always kept: it is a whole-range language report
    /// rather than a flag on a span, and dropping it (it intersects every
    /// exclusion in the note) would leave the checker without a language.
    /// Everything else — spelling, grammar, and the `.correction` /
    /// `.replacement` substitutions — is dropped when it touches markup.
    public static func keeping(
        _ results: [NSTextCheckingResult], excluding exclusions: [NSRange]
    ) -> [NSTextCheckingResult] {
        guard !exclusions.isEmpty else { return results }
        return results.filter { result in
            if result.resultType == .orthography {
                return true
            }
            return !exclusions.contains { NSIntersectionRange($0, result.range).length > 0 }
        }
    }

    /// Sorted, non-overlapping ranges. Abutting spans merge too: `#a#b`
    /// styles as two chips, and one span over both is cheaper to test.
    static func coalesced(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard let first = sorted.first else { return [] }
        var merged = [first]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `https://…`, `www.…` — stops at whitespace or markdown punctuation
    /// so a URL at the end of a sentence doesn't swallow the next word.
    private static let bareURLRegex = try? NSRegularExpression(
        pattern: #"(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>\[\]()"'`]+"#,
        options: [.caseInsensitive]
    )
    /// `<https://example.com>` — CommonMark's angle autolink.
    private static let angleAutolinkRegex = try? NSRegularExpression(
        pattern: #"<[a-z][a-z0-9+.-]*:[^\s<>]*>"#,
        options: [.caseInsensitive]
    )
}

/// The three proofing knobs, as one comparable value: the editor only
/// re-requests a check when they actually change.
struct ProofingFlags: Equatable {
    var spelling: Bool
    var grammar: Bool
    var autocorrect: Bool

    /// Grammar rides along with spelling — asking for grammar alone checks
    /// nothing, because the system grammar pass runs inside the spelling
    /// one (see NSTextView.h: "If grammar checking is enabled, then it is
    /// performed whenever spellchecking is performed").
    var checkingTypes: NSTextCheckingTypes {
        var types = NSTextCheckingResult.CheckingType.spelling.rawValue
        if grammar {
            types |= NSTextCheckingResult.CheckingType.grammar.rawValue
        }
        return types
    }
}

/// App-startup switch for the system spell checker. AppKit silently REFUSES
/// `isContinuousSpellCheckingEnabled` (and grammar checking with it) unless
/// the `NSAllowContinuousSpellChecking` default reads true — the setter
/// takes, the getter comes back false, nothing is ever checked. Some user
/// accounts hold 0 in NSGlobalDomain for that key (this machine did), which
/// is why the editor never showed a squiggle. Writing true into the app's
/// OWN domain outranks the global value without touching it. AppKit caches
/// the answer for the process lifetime, so this must run before any text
/// view exists — call it from the App's init, not from a view.
public enum ProofingBootstrap {
    public static let allowContinuousSpellCheckingKey = "NSAllowContinuousSpellChecking"

    public static func allowContinuousSpellChecking(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: allowContinuousSpellCheckingKey) else { return }
        defaults.set(true, forKey: allowContinuousSpellCheckingKey)
    }
}

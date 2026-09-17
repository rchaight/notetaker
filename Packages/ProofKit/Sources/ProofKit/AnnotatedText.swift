import Foundation

/// LanguageTool's "annotated text" input: an ordered list of segments, each
/// either `text` (checked for grammar) or `markup` (passed straight
/// through, never flagged, but still occupying its own space in the
/// reconstructed string). Every excluded range — code spans, `#tag`s,
/// links, task tokens — becomes a `markup` segment holding that exact
/// slice of the original text, unchanged.
///
/// That "unchanged" part is the whole trick: concatenating every segment's
/// text (`text` or `markup`, in order) reproduces the input string
/// character-for-character, UTF-16 code unit for UTF-16 code unit. Because
/// LanguageTool is a Java tool — a Java `char` IS one UTF-16 code unit —
/// its `matches[].offset`/`length` come back in the same units Swift's
/// `NSRange` already uses. So once the annotation tiles the original text
/// exactly (verified below by round-tripping it, including through an
/// emoji's surrogate pair and CRLF line endings), a match's `offset`/
/// `length` can be wrapped directly as `NSRange(location:length:)` against
/// the ORIGINAL text — no coordinate conversion, no remapping pass.
public enum AnnotatedText {
    /// One annotation entry: exactly one of `text`/`markup` is non-nil.
    public struct Segment: Equatable, Sendable {
        public let text: String?
        public let markup: String?

        public init(text: String? = nil, markup: String? = nil) {
            self.text = text
            self.markup = markup
        }
    }

    /// Builds the segment list for `text`, turning every range in
    /// `excluding` into `markup`. Ranges may be given in any order and may
    /// overlap or touch — they're clamped to `text`'s bounds, sorted, and
    /// merged first, so the result always alternates non-empty `text`/
    /// `markup` runs that together cover the whole string exactly once.
    public static func build(text: String, excluding: [NSRange]) -> [Segment] {
        let ns = text as NSString
        let length = ns.length
        let merged = mergedRanges(excluding, length: length)
        guard !merged.isEmpty else {
            return length == 0 ? [] : [Segment(text: text)]
        }

        var segments: [Segment] = []
        var cursor = 0
        for range in merged {
            if range.location > cursor {
                segments.append(Segment(text: ns.substring(with: NSRange(
                    location: cursor,
                    length: range.location - cursor
                ))))
            }
            segments.append(Segment(markup: ns.substring(with: range)))
            cursor = NSMaxRange(range)
        }
        if cursor < length {
            segments.append(Segment(text: ns.substring(with: NSRange(location: cursor, length: length - cursor))))
        }
        return segments
    }

    /// The exact string LanguageTool would reconstruct from `segments` —
    /// used by tests to assert the round-trip; not needed at request time.
    public static func reconstruct(_ segments: [Segment]) -> String {
        segments.reduce(into: "") { result, segment in
            result += segment.text ?? segment.markup ?? ""
        }
    }

    /// The JSON string for LanguageTool's `data` form parameter:
    /// `{"annotation":[{"text":"…"},{"markup":"…"},…]}`.
    public static func json(for segments: [Segment]) -> String {
        let annotation: [[String: String]] = segments.map { segment in
            if let text = segment.text {
                ["text": text]
            } else {
                ["markup": segment.markup ?? ""]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["annotation": annotation]),
              let string = String(data: data, encoding: .utf8)
        else { return "{\"annotation\":[]}" }
        return string
    }

    /// Clamps every range to `0..<length`, drops empties, sorts, and merges
    /// overlapping/touching ranges so two adjacent exclusions never leave a
    /// zero-length `text` gap between them.
    private static func mergedRanges(_ ranges: [NSRange], length: Int) -> [NSRange] {
        let clamped: [NSRange] = ranges.compactMap { range in
            guard range.location != NSNotFound else { return nil }
            let start = max(0, min(range.location, length))
            let end = max(start, min(NSMaxRange(range), length))
            let clampedRange = NSRange(location: start, length: end - start)
            return clampedRange.length > 0 ? clampedRange : nil
        }.sorted { $0.location < $1.location }

        var merged: [NSRange] = []
        for range in clamped {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

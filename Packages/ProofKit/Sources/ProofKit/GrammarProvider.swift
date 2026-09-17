import Foundation

/// One grammar/style backend. LanguageTool today; the shape leaves room for
/// another provider without touching call sites.
public protocol GrammarProvider: Sendable {
    /// Checks `text` for grammar/style issues. `excluding` are UTF-16
    /// ranges IN `text` that must never be flagged (code spans, `#tag`s,
    /// task tokens…) — the caller computes these; a provider that can't
    /// honor them at all should just ignore the argument, but LanguageTool
    /// exists precisely so it doesn't have to. `language` is a LanguageTool
    /// language code, or nil/"auto" to auto-detect.
    func check(_ text: String, excluding: [NSRange], language: String?) async throws -> [GrammarMatch]
}

public extension GrammarProvider {
    /// Convenience for call sites that don't care about excluding anything
    /// or picking a language.
    func check(_ text: String) async throws -> [GrammarMatch] {
        try await check(text, excluding: [], language: nil)
    }
}

/// One flagged span, already translated into the ORIGINAL text's UTF-16
/// coordinate space — callers never see LanguageTool's own offset units.
public struct GrammarMatch: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// UTF-16 range in the text that was checked.
    public let range: NSRange
    public let message: String
    public let shortMessage: String
    public let replacements: [String]
    public let ruleId: String
    public let category: String

    public init(
        id: UUID = UUID(),
        range: NSRange,
        message: String,
        shortMessage: String,
        replacements: [String],
        ruleId: String,
        category: String
    ) {
        self.id = id
        self.range = range
        self.message = message
        self.shortMessage = shortMessage
        self.replacements = replacements
        self.ruleId = ruleId
        self.category = category
    }
}

public extension GrammarMatch {
    /// After a caller Applies `applied`'s replacement (new UTF-16 length
    /// `newLength`), every OTHER match's range needs adjusting: matches
    /// entirely before the edit are untouched, matches entirely at/after
    /// the edit shift by the length delta, and matches overlapping the
    /// edited span are dropped — the edit invalidated whatever they were
    /// pointing at, and only a fresh check can say anything sound about
    /// that span now. This is pure offset arithmetic (chosen over
    /// re-running the check after every Apply): it's instant, needs no
    /// network round-trip, and the sheet already has everything it needs
    /// in memory.
    static func shifted(_ matches: [GrammarMatch], afterApplying applied: GrammarMatch,
                        newLength: Int) -> [GrammarMatch] {
        let delta = newLength - applied.range.length
        let editEnd = NSMaxRange(applied.range)
        return matches.compactMap { match in
            guard match.id != applied.id else { return nil } // consumed
            if NSMaxRange(match.range) <= applied.range.location {
                return match
            }
            if match.range.location >= editEnd {
                return GrammarMatch(
                    id: match.id,
                    range: NSRange(location: match.range.location + delta, length: match.range.length),
                    message: match.message,
                    shortMessage: match.shortMessage,
                    replacements: match.replacements,
                    ruleId: match.ruleId,
                    category: match.category
                )
            }
            return nil // overlaps the edited span — stale
        }
    }
}

/// Typed failures — a malformed/unreachable server must never crash the
/// Proofread panel, only report itself honestly.
public enum GrammarError: Error, Equatable, Sendable {
    case unreachable(String)
    case timeout
    case badResponse(String)
}

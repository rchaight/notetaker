import Foundation

/// Tag-merge suggestion: fold `from` tags into `into`.
public struct TagMerge: Equatable, Sendable, Codable, Identifiable {
    public var id: String {
        into + "←" + from.joined(separator: ",")
    }

    public let from: [String]
    public let into: String
    public let reason: String

    public init(from: [String], into: String, reason: String) {
        self.from = from
        self.into = into
        self.reason = reason
    }
}

/// Deterministic tag-curation heuristics — the offline tier under the AI
/// suggestions, and the sanity filter over them. Suggests folding the
/// LOWER-count variant into the higher.
public enum TagCuration {
    public static func heuristicMerges(tags: [(tag: String, count: Int)]) -> [TagMerge] {
        var suggestions: [TagMerge] = []
        var claimed = Set<String>()
        let ranked = tags.sorted { $0.count > $1.count }

        func canonical(_ tag: String) -> String {
            var folded = tag.lowercased()
                .replacingOccurrences(of: "_", with: "-")
            if folded.hasSuffix("s"), folded.count > 3 {
                folded = String(folded.dropLast())
            }
            return folded
        }

        var byCanonical: [String: (tag: String, count: Int)] = [:]
        for entry in ranked {
            let key = canonical(entry.tag)
            if let winner = byCanonical[key] {
                guard !claimed.contains(entry.tag), entry.tag != winner.tag else { continue }
                claimed.insert(entry.tag)
                suggestions.append(TagMerge(
                    from: [entry.tag],
                    into: winner.tag,
                    reason: reasonFor(variant: entry.tag, winner: winner.tag)
                ))
            } else {
                byCanonical[key] = entry
            }
        }
        return suggestions
    }

    private static func reasonFor(variant: String, winner: String) -> String {
        if variant.lowercased() == winner.lowercased() {
            return "case variant"
        }
        if variant.lowercased().hasSuffix("s") || winner.lowercased().hasSuffix("s") {
            return "singular/plural"
        }
        return "separator variant"
    }

    /// Drops AI suggestions that reference unknown tags or self-merges —
    /// model output is never trusted to name real tags.
    public static func validated(
        _ merges: [TagMerge], against tags: [(tag: String, count: Int)]
    ) -> [TagMerge] {
        let known = Set(tags.map(\.tag))
        return merges.compactMap { merge in
            let sources = merge.from.filter { known.contains($0) && $0 != merge.into }
            guard !sources.isEmpty, known.contains(merge.into) else { return nil }
            return TagMerge(from: sources, into: merge.into, reason: merge.reason)
        }
    }
}

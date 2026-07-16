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

/// Group suggestion: rename members under a common parent path
/// ("meeting-notes" → "meeting/notes") — organizes without deleting.
public struct TagGroup: Equatable, Sendable, Codable, Identifiable {
    public var id: String {
        parent + "⇐" + members.joined(separator: ",")
    }

    public let parent: String
    public let members: [String]
    public let reason: String

    public init(parent: String, members: [String], reason: String) {
        self.parent = parent
        self.members = members
        self.reason = reason
    }

    /// The nested name a member becomes when the group applies.
    public static func nestedName(member: String, parent: String) -> String {
        let leaf = member.hasPrefix(parent + "-") || member.hasPrefix(parent + "_")
            ? String(member.dropFirst(parent.count + 1))
            : member
        return parent + "/" + leaf
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

    /// Prefix grouping: ≥2 tags sharing a hyphen/underscore prefix become
    /// a nested family ("meeting-notes", "meeting-agenda" → meeting/…).
    public static func heuristicGroups(tags: [(tag: String, count: Int)]) -> [TagGroup] {
        var byPrefix: [String: [String]] = [:]
        let flat = tags.map(\.tag).filter { !$0.contains("/") }
        for tag in flat {
            guard let separator = tag.firstIndex(where: { $0 == "-" || $0 == "_" }),
                  separator != tag.startIndex else { continue }
            let prefix = String(tag[..<separator]).lowercased()
            byPrefix[prefix, default: []].append(tag)
        }
        return byPrefix
            .filter { $0.value.count >= 2 }
            .sorted { $0.key < $1.key }
            .map { prefix, members in
                TagGroup(
                    parent: prefix,
                    members: members.sorted(),
                    reason: "shared \"\(prefix)\" prefix"
                )
            }
    }

    /// Group suggestions from a model, sanity-filtered: members must be
    /// real flat tags; parent must be a plausible tag name.
    public static func validatedGroups(
        _ groups: [TagGroup], against tags: [(tag: String, count: Int)]
    ) -> [TagGroup] {
        let known = Set(tags.map(\.tag))
        return groups.compactMap { group in
            let members = group.members.filter {
                known.contains($0) && !$0.contains("/") && $0 != group.parent
            }
            guard members.count >= 2,
                  !group.parent.isEmpty,
                  group.parent.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { return nil }
            return TagGroup(parent: group.parent, members: members, reason: group.reason)
        }
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

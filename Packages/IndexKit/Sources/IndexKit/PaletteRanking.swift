import Foundation

/// Command-palette ranking: a pure function from a query and the palette's
/// candidates to ordered rows. Foundation only — no database, no UI — so the
/// whole ordering policy is unit-tested here and the app just renders it.
public enum PaletteRanking {
    /// A note the palette can open. `title` is the file name without `.md`.
    public struct Note: Sendable, Equatable {
        public let id: String
        public let title: String
        public let folder: String?

        public init(id: String, title: String, folder: String? = nil) {
            self.id = id
            self.title = title
            self.folder = folder
        }
    }

    public struct Candidate: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            /// A command, by the id the caller passed in.
            case command(String)
            /// A note, by note id.
            case note(String)
            /// A note found by its body text (FTS), by note id.
            case bodyHit(String)
        }

        /// `"cmd:<id>"` / `"note:<id>"` / `"body:<id>"` — unique across kinds.
        public let id: String
        public let kind: Kind
        public let title: String
        /// Folder for notes, shortcut label for commands.
        public let subtitle: String?
        public let score: Int

        public init(id: String, kind: Kind, title: String, subtitle: String?, score: Int) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.score = score
        }
    }

    // Tier values; each tier outranks every lower one even after the length
    // and recents adjustments (those are < 100 and < 200 respectively).
    static let exactScore = 1000
    static let prefixScore = 800
    static let wordPrefixScore = 600
    static let substringScore = 400
    static let subsequenceScore = 200

    static let emptyQueryRecentLimit = 5
    static let emptyQueryCommandLimit = 8
    static let commandLimit = 6
    static let noteLimit = 10
    static let bodyHitLimit = 5

    /// Score of `title` for `query`, or nil for no match. The query is split
    /// on whitespace; every token must match and the token scores add. A
    /// token scores by the best tier it reaches — exact 1000, prefix 800,
    /// prefix of any word 600, substring 400, characters in order 200 — and
    /// the total loses `title.count / 10` so shorter titles win ties. Case-
    /// and diacritic-insensitive.
    public static func score(query: String, title: String) -> Int? {
        score(tokens: tokens(of: query), title: title, folder: nil)
    }

    /// Empty query → recents (max 5, in order, score 0) then the first 8
    /// commands in table order. Otherwise commands (≤ 6) then notes (≤ 10),
    /// each sorted by score descending, then title. Notes get a recents bonus
    /// of `100 - 10 × index`, and a token that only matches a note's folder
    /// earns substring credit.
    public static func rank(
        query: String,
        commands: [(id: String, title: String, shortcut: String?)],
        notes: [Note],
        recents: [String]
    ) -> [Candidate] {
        let queryTokens = tokens(of: query)
        if queryTokens.isEmpty {
            return emptyQueryRows(commands: commands, notes: notes, recents: recents)
        }

        var commandRows: [Candidate] = []
        for command in commands {
            guard let value = score(tokens: queryTokens, title: command.title, folder: nil) else { continue }
            commandRows.append(commandCandidate(command, score: value))
        }

        var noteRows: [Candidate] = []
        for note in notes {
            guard let base = score(tokens: queryTokens, title: note.title, folder: note.folder) else { continue }
            var value = base
            if let index = recents.firstIndex(of: note.id) {
                value += max(0, 100 - 10 * index)
            }
            noteRows.append(noteCandidate(note, score: value))
        }

        return Array(sorted(commandRows).prefix(commandLimit)) + Array(sorted(noteRows).prefix(noteLimit))
    }

    /// Body hits from FTS (already in relevance order): the notes the ids
    /// name, minus anything already listed as a title row or body row, max 5.
    /// Ids that match no known note (stale index rows) are dropped.
    public static func bodyHits(_ ids: [String], notes: [Note], excluding: [Candidate]) -> [Candidate] {
        var listed = Set<String>()
        for candidate in excluding {
            switch candidate.kind {
            case let .note(id), let .bodyHit(id): listed.insert(id)
            case .command: break
            }
        }
        let byId = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [Candidate] = []
        for id in ids {
            guard rows.count < bodyHitLimit else { break }
            guard let note = byId[id], listed.insert(id).inserted else { continue }
            rows.append(Candidate(
                id: "body:\(id)", kind: .bodyHit(id), title: note.title, subtitle: note.folder, score: 0
            ))
        }
        return rows
    }

    // MARK: Internals

    private static func emptyQueryRows(
        commands: [(id: String, title: String, shortcut: String?)],
        notes: [Note],
        recents: [String]
    ) -> [Candidate] {
        let byId = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [Candidate] = []
        var seen = Set<String>()
        for id in recents {
            guard rows.count < emptyQueryRecentLimit else { break }
            guard let note = byId[id], seen.insert(id).inserted else { continue }
            rows.append(noteCandidate(note, score: 0))
        }
        for command in commands.prefix(emptyQueryCommandLimit) {
            rows.append(commandCandidate(command, score: 0))
        }
        return rows
    }

    private static func commandCandidate(
        _ command: (id: String, title: String, shortcut: String?), score: Int
    ) -> Candidate {
        Candidate(
            id: "cmd:\(command.id)", kind: .command(command.id),
            title: command.title, subtitle: command.shortcut, score: score
        )
    }

    private static func noteCandidate(_ note: Note, score: Int) -> Candidate {
        Candidate(id: "note:\(note.id)", kind: .note(note.id), title: note.title, subtitle: note.folder, score: score)
    }

    /// Score descending, then title (folded, so "alpha" sorts with "Alpha"),
    /// then id — a total order, so equal-scoring rows never shuffle.
    private static func sorted(_ rows: [Candidate]) -> [Candidate] {
        rows.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let left = fold(lhs.title)
            let right = fold(rhs.title)
            if left != right {
                return left < right
            }
            return lhs.id < rhs.id
        }
    }

    private static func tokens(of query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func score(tokens: [String], title: String, folder: String?) -> Int? {
        guard !tokens.isEmpty else { return nil }
        let foldedTitle = fold(title)
        let words = foldedTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let foldedFolder = folder.map(fold)
        var total = 0
        for token in tokens {
            var best = tokenScore(token, in: foldedTitle, words: words)
            if let foldedFolder, foldedFolder.contains(token) {
                best = max(best ?? 0, substringScore)
            }
            guard let best else { return nil }
            total += best
        }
        return total - title.count / 10
    }

    private static func tokenScore(_ token: String, in title: String, words: [Substring]) -> Int? {
        if title == token {
            return exactScore
        }
        if title.hasPrefix(token) {
            return prefixScore
        }
        if words.contains(where: { $0.hasPrefix(token) }) {
            return wordPrefixScore
        }
        if title.contains(token) {
            return substringScore
        }
        if isSubsequence(token, of: title) {
            return subsequenceScore
        }
        return nil
    }

    private static func isSubsequence(_ token: String, of title: String) -> Bool {
        var remaining = token.makeIterator()
        var wanted = remaining.next()
        for character in title {
            guard let target = wanted else { break }
            if character == target {
                wanted = remaining.next()
            }
        }
        return wanted == nil
    }
}

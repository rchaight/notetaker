import Foundation
import MCP

public extension VaultService {
    enum SearchMode: String, Sendable, CaseIterable {
        case keyword
        case semantic
        case hybrid
    }

    /// Hybrid retrieval: FTS5/BM25 ranking from the index fused with cosine
    /// similarity over the note chunks the app already embedded. Both halves
    /// degrade quietly — no index means a file scan, no embedding assets
    /// means keyword only.
    func search(query: String, mode: SearchMode = .hybrid, limit: Int = 10) async -> Value {
        let terms = Self.terms(in: query)
        var keywordRanking: [String] = []
        var semanticRanking: [(noteId: String, score: Float, text: String)] = []
        var usedIndex = false
        var semanticUsed = false
        var semanticNote: String?

        if mode != .semantic, let ids = keywordNoteIds(query: query, limit: limit * 3) {
            keywordRanking = ids
            usedIndex = true
        }
        if mode != .keyword, index != nil {
            // Embedding the query needs the NLContextualEmbedding assets. A
            // CLI usually has them; when it doesn't, say so and move on.
            if let vector = try? await embeddings.embed([query]).first, !vector.isEmpty,
               let matches = withIndex({ try $0.semanticMatches(query: vector, limit: limit * 3) }),
               !matches.isEmpty {
                semanticRanking = matches
                semanticUsed = true
                usedIndex = true
            } else {
                semanticNote = "semantic search unavailable — keyword only"
            }
        } else if mode != .keyword {
            semanticNote = "semantic search needs the index — keyword only"
        }

        var results: [Value] = if usedIndex {
            fuse(
                keyword: keywordRanking, semantic: semanticRanking, terms: terms, limit: limit
            )
        } else {
            scanSearch(terms: terms, limit: limit)
        }
        if results.isEmpty, usedIndex {
            // An index that knows nothing about this query still shouldn't
            // shadow the files.
            let scanned = scanSearch(terms: terms, limit: limit)
            if !scanned.isEmpty {
                results = scanned
                usedIndex = false
            }
        }

        var payload: [String: Value] = [
            "source": .string(usedIndex ? "index" : "scan"),
            "query": .string(query),
            "mode": .string(mode.rawValue),
            "semantic": .bool(semanticUsed),
            "results": .array(results),
        ]
        if let semanticNote, mode != .keyword {
            payload["note"] = .string(semanticNote)
        }
        return .object(payload)
    }

    // MARK: - Keyword half

    private func keywordNoteIds(query: String, limit: Int) -> [String]? {
        let terms = Self.terms(in: query)
        guard !terms.isEmpty else { return nil }
        let quoted = terms.map { "\"\($0)\"" }
        // AND first (precise), then OR so a long question still finds
        // something rather than nothing.
        if let all = withIndex({ try $0.searchNoteIds(matching: quoted.joined(separator: " "), limit: limit) }),
           !all.isEmpty {
            return all
        }
        return withIndex { try $0.searchNoteIds(matching: quoted.joined(separator: " OR "), limit: limit) }
    }

    /// Reciprocal rank fusion — rank-based, so BM25 scores and cosine
    /// similarities never have to be forced onto one scale.
    private func fuse(
        keyword: [String], semantic: [(noteId: String, score: Float, text: String)],
        terms: [String], limit: Int
    ) -> [Value] {
        let k = 60.0
        var scores: [String: Double] = [:]
        var matchedBy: [String: Set<String>] = [:]
        var chunkText: [String: String] = [:]

        for (rank, noteId) in keyword.enumerated() {
            scores[noteId, default: 0] += 1.0 / (k + Double(rank + 1))
            matchedBy[noteId, default: []].insert("keyword")
        }
        for (rank, match) in semantic.enumerated() {
            scores[match.noteId, default: 0] += 1.0 / (k + Double(rank + 1))
            matchedBy[match.noteId, default: []].insert("semantic")
            chunkText[match.noteId] = match.text
        }

        return scores
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { noteId, score in
                entry(
                    noteId: noteId,
                    score: score,
                    matchedBy: matchedBy[noteId] ?? [],
                    terms: terms,
                    chunk: chunkText[noteId]
                )
            }
    }

    private func entry(
        noteId: String, score: Double, matchedBy: Set<String>, terms: [String], chunk: String?
    ) -> Value {
        let url = location.root.appendingPathComponent(noteId)
        let title = (noteId as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        var payload: [String: Value] = [
            "path": .string(noteId),
            "title": .string(title),
            "score": .double((score * 10000).rounded() / 10000),
            "matched_by": .array(matchedBy.sorted().map { .string($0) }),
        ]
        // Snippets come from the FILE, so a locked note is caught by a full
        // frontmatter parse rather than a truncated peek.
        let contents = VaultFiles.quickRead(url)
        let note = contents.map { NoteReader.note(from: $0, relativePath: noteId) }
        if note?.locked == true {
            payload["locked"] = .bool(true)
            return .object(payload)
        }
        payload["locked"] = .bool(false)
        // A snippet built around the query terms beats the embedded chunk
        // whenever the terms are actually in the note; the chunk is the
        // fallback for semantic-only hits that share no words with the query.
        if let snippet = note?.body.flatMap({ Self.snippet(in: $0, terms: terms) })
            ?? chunk.map({ Self.condense($0, limit: 320) }) {
            payload["snippet"] = .string(snippet)
        }
        return .object(payload)
    }

    // MARK: - Scan fallback

    private func scanSearch(terms: [String], limit: Int) -> [Value] {
        guard !terms.isEmpty else { return [] }
        var hits: [(path: String, score: Double, body: String?, locked: Bool)] = []
        for file in VaultFiles.markdownFiles(in: location.root) {
            guard let contents = VaultFiles.quickRead(file.url) else { continue }
            let note = NoteReader.note(from: contents, relativePath: file.relativePath)
            let haystack = (note.locked ? file.relativePath : contents).lowercased()
            var score = 0.0
            for term in terms {
                let occurrences = haystack.components(separatedBy: term).count - 1
                guard occurrences > 0 else { continue }
                score += Double(occurrences)
                if file.title.lowercased().contains(term) {
                    score += 10
                }
            }
            guard score > 0 else { continue }
            hits.append((file.relativePath, score, note.body, note.locked))
        }
        return hits
            .sorted { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
            .prefix(limit)
            .map { hit in
                var payload: [String: Value] = [
                    "path": .string(hit.path),
                    "title": .string(
                        (hit.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
                    ),
                    "score": .double((hit.score * 100).rounded() / 100),
                    "matched_by": .array([.string("keyword")]),
                    "locked": .bool(hit.locked),
                ]
                if !hit.locked, let body = hit.body, let snippet = Self.snippet(in: body, terms: terms) {
                    payload["snippet"] = .string(snippet)
                }
                return .object(payload)
            }
    }

    // MARK: - Text helpers

    /// Query → FTS-safe lowercase terms. Anything that isn't a letter or a
    /// digit separates; that keeps punctuation out of FTS5's grammar.
    static func terms(in query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 || $0.first?.isNumber == true }
    }

    /// A window of the body around the first query term. nil when the note
    /// matched on something other than its words — the caller then quotes
    /// the semantically matched chunk instead.
    static func snippet(in body: String, terms: [String], radius: Int = 140) -> String? {
        let lowered = body.lowercased()
        guard let found = terms.compactMap({ lowered.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let start = body.index(
            found.lowerBound, offsetBy: -radius, limitedBy: body.startIndex
        ) ?? body.startIndex
        let end = body.index(found.upperBound, offsetBy: radius, limitedBy: body.endIndex) ?? body.endIndex
        let leading = start > body.startIndex ? "…" : ""
        let trailing = end < body.endIndex ? "…" : ""
        return leading + condense(String(body[start ..< end]), limit: radius * 3) + trailing
    }

    static func condense(_ text: String, limit: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count <= limit ? flattened : String(flattened.prefix(limit)) + "…"
    }
}

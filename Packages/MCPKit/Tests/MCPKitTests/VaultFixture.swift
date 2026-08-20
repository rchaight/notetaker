import AIKit
import Foundation
import IndexKit
@testable import MCPKit

/// A throwaway vault on disk plus (optionally) the index the app would have
/// built from it. Every test gets its own copy.
struct VaultFixture {
    let root: URL
    let indexPath: String

    static let notes: [String: String] = [
        "CLAUDE.md": """
        # Notetaker vault
        Read `_index.md` in each folder before opening notes.
        """,
        "_index.md": """
        # Vault
        - 📁 Work
        - 📁 Daily
        """,
        "Inbox.md": """
        # Inbox
        - [ ] book the accreditation site visit >2026-08-25 !p1 #accreditation @dana
        """,
        "Work/_index.md": """
        # Work
        - [Curriculum](Work/Curriculum.md)
        """,
        "Work/Curriculum.md": """
        ---
        area: Curriculum
        ---
        # Curriculum redesign

        The pharmacology thread needs a spiral structure so students revisit
        drug mechanisms in every year of the program.

        - [ ] draft the spiral map >2026-08-22 !p2 #curriculum @dana ?discuss
        - [x] collect the old syllabi ✅2026-08-01 #curriculum
        """,
        "Work/Locked.md": """
        ---
        locked: true
        ---
        U2FsdGVkX1+ciphertextciphertextciphertext pharmacology
        """,
        "Daily/2026-08-20.md": """
        # 2026-08-20

        - [ ] email the dean about budget >2026-09-30 @dean ?waiting
        """,
    ]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpkit-vault-\(UUID().uuidString)", isDirectory: true)
        indexPath = root.appendingPathComponent("index.sqlite").path
        for (path, contents) in Self.notes {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds the index exactly the way the app's pipeline does, plus the
    /// embedding chunks semantic search reads.
    func buildIndex(embeddings: StubEmbeddings? = nil) throws {
        let (database, _) = try IndexDatabase.open(path: indexPath)
        let indexer = NoteIndexer(database: database)
        for (path, contents) in Self.notes.sorted(by: { $0.key < $1.key }) {
            guard path.hasSuffix(".md"), !path.hasSuffix("_index.md") else { continue }
            try indexer.index(noteId: path, contents: contents, modifiedAt: Date())
            // Locked notes hold ciphertext: the app never embeds them, and
            // neither does the fixture.
            if let embeddings, !contents.contains("locked: true") {
                try database.replaceChunks(
                    noteId: path,
                    chunks: [(text: String(contents.prefix(200)), embedding: embeddings.vector(for: contents))]
                )
            }
        }
    }

    func location(withIndex: Bool) -> VaultLocation {
        VaultLocation(
            root: root, indexPath: withIndex ? indexPath : nil, origin: .argument
        )
    }

    func service(withIndex: Bool, embeddings: any EmbeddingProvider = StubEmbeddings()) -> VaultService {
        VaultService(location: location(withIndex: withIndex), embeddings: embeddings)
    }
}

/// Deterministic bag-of-words embedding — real enough that cosine ranks the
/// right note first, with no NLContextualEmbedding assets involved.
struct StubEmbeddings: EmbeddingProvider {
    static let vocabulary = [
        "pharmacology", "curriculum", "accreditation", "budget", "dean", "spiral", "inbox",
    ]
    var available = true

    func isAvailable() async -> Bool {
        available
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard available else { throw AIProviderError.unavailable("stub") }
        return texts.map(vector(for:))
    }

    func vector(for text: String) -> [Float] {
        let lowered = text.lowercased()
        return Self.vocabulary.map { lowered.contains($0) ? 1 : 0 }
    }
}

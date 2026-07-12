import Foundation
import NaturalLanguage

/// Sentence embeddings for semantic search. On-device via
/// NLContextualEmbedding; falls back to unavailable (search stays FTS-only).
public protocol EmbeddingProvider: Sendable {
    func isAvailable() async -> Bool
    /// One vector per input text; all vectors share a dimension.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public struct AppleEmbeddingProvider: EmbeddingProvider {
    public init() {}

    public func isAvailable() async -> Bool {
        guard let embedding = NLContextualEmbedding(language: .english) else { return false }
        if embedding.hasAvailableAssets {
            return true
        }
        // One-time model download (small); fails quietly offline.
        return await (try? embedding.requestAssets()) == .available
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let embedding = NLContextualEmbedding(language: .english),
              embedding.hasAvailableAssets
        else { throw AIProviderError.unavailable("contextual embedding assets missing") }
        try embedding.load()
        defer { embedding.unload() }

        return try texts.map { text in
            let result = try embedding.embeddingResult(for: text, language: .english)
            // Mean-pool token vectors into one sentence vector.
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() {
                    sum[index] += value
                }
                count += 1
                return true
            }
            guard count > 0 else { return [Float](repeating: 0, count: embedding.dimension) }
            return sum.map { Float($0 / Double(count)) }
        }
    }
}

/// Chunking for embedding: paragraph-grouped windows that respect the
/// model's effective context.
public enum EmbeddingChunker {
    public static func chunks(from body: String, maxLength: Int = 800) -> [String] {
        var chunks: [String] = []
        var current = ""
        for paragraph in body.split(separator: "\n\n", omittingEmptySubsequences: true) {
            let piece = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if current.isEmpty {
                current = piece
            } else if current.count + piece.count + 2 <= maxLength {
                current += "\n\n" + piece
            } else {
                chunks.append(current)
                current = piece
            }
            // Oversized single paragraphs get hard-split.
            while current.count > maxLength {
                chunks.append(String(current.prefix(maxLength)))
                current = String(current.dropFirst(maxLength))
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

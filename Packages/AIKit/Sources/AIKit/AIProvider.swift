import Foundation

/// A structured task produced by an AI (or deterministic) parser.
public struct AITask: Equatable, Sendable {
    public let text: String
    public let dueDate: String? // ISO yyyy-MM-dd
    public let priority: Int? // 1…4
    public let labels: [String]

    public init(text: String, dueDate: String?, priority: Int?, labels: [String]) {
        self.text = text
        self.dueDate = dueDate
        self.priority = priority
        self.labels = labels
    }

    /// The vault representation — one grammar everywhere.
    public var markdownLine: String {
        var line = "- [ ] \(text)"
        if let dueDate {
            line += " >\(dueDate)"
        }
        if let priority {
            line += " !p\(priority)"
        }
        line += labels.map { " #\($0)" }.joined()
        return line
    }
}

public extension AIProvider {
    var contextLimit: Int? {
        nil
    }

    /// Cheap token estimate (~4 chars/token) for routing decisions.
    static func estimatedTokens(_ text: String) -> Int {
        text.utf8.count / 4
    }
}

public enum AIProviderError: Error, Equatable, Sendable {
    case unavailable(String)
    case failed(String)
}

/// One AI backend. Private/on-device by default: FoundationModels → Ollama
/// (homelab) → None (deterministic) — the app must stay fully usable when
/// every model is missing.
public protocol AIProvider: Sendable {
    var name: String { get }
    /// Rough input-token ceiling; nil = unbounded. The router skips
    /// providers whose window the input exceeds.
    var contextLimit: Int? { get }
    func isAvailable() async -> Bool
    func summarize(_ text: String) async throws -> String
    func extractActionItems(from text: String) async throws -> [AITask]
    func parseTask(_ input: String) async throws -> AITask
}

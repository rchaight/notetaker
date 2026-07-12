import Foundation
import TaskEngine

/// The deterministic floor: no model, no network, always available.
/// Task parsing rides the real QuickAdd grammar; summarize/extract are
/// honest heuristics labeled as such.
public struct NoneProvider: AIProvider {
    public let name = "Basic (no AI)"

    public init() {}

    public func isAvailable() async -> Bool {
        true
    }

    /// Extractive: lead sentences, capped.
    public func summarize(_ text: String) async throws -> String {
        let sentences = text
            .replacingOccurrences(of: #"^#+\s.*$"#, with: "", options: [.regularExpression])
            .split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 20 }
        guard !sentences.isEmpty else { throw AIProviderError.failed("nothing to summarize") }
        return sentences.prefix(3).joined(separator: ". ") + "."
    }

    /// Conservative heuristic: lines that already read like actions.
    public func extractActionItems(from text: String) async throws -> [AITask] {
        let actionPattern = try NSRegularExpression(
            pattern: #"(?i)^\s*(?:[-*]\s+)?(?:TODO:?\s+|ACTION:?\s+)(.+)$|(?i)^\s*(?:[-*]\s+)?(?:\w+[ ,]+){0,3}((?:need to|needs to|must|should|remember to|don't forget to)\s+.+)$"#
        )
        var tasks: [AITask] = []
        for line in text.split(separator: "\n") {
            let string = String(line)
            guard !string.contains("- [ ]"), !string.contains("- [x]") else { continue }
            let range = NSRange(location: 0, length: (string as NSString).length)
            guard let match = actionPattern.firstMatch(in: string, range: range) else { continue }
            let ns = string as NSString
            let captured = match.range(at: 1).location != NSNotFound
                ? ns.substring(with: match.range(at: 1))
                : ns.substring(with: match.range(at: 2))
            let parsed = QuickAddParser.parse(captured)
            if let parsed {
                tasks.append(AITask(
                    text: parsed.metadata.cleanText,
                    dueDate: parsed.metadata.dueDate,
                    priority: parsed.metadata.priority,
                    labels: parsed.metadata.labels
                ))
            }
        }
        return tasks
    }

    public func parseTask(_ input: String) async throws -> AITask {
        guard let parsed = QuickAddParser.parse(input) else {
            throw AIProviderError.failed("empty input")
        }
        return AITask(
            text: parsed.metadata.cleanText,
            dueDate: parsed.metadata.dueDate,
            priority: parsed.metadata.priority,
            labels: parsed.metadata.labels
        )
    }
}

import Foundation
import TaskEngine

#if canImport(FoundationModels)
    import FoundationModels

    /// Apple Intelligence on-device tier. ~4k-token context — the router
    /// sends longer inputs to Ollama.
    public struct FoundationModelsProvider: AIProvider {
        public let name = "Apple Intelligence"

        /// The on-device model's practical window; longer inputs route to
        /// Ollama.
        public var contextLimit: Int? {
            3000
        }

        public init() {}

        public func isAvailable() async -> Bool {
            SystemLanguageModel.default.availability == .available
        }

        @Generable
        struct GeneratedTask {
            @Guide(description: "The task description, imperative, without dates or priorities")
            var text: String
            @Guide(description: "Due date as yyyy-MM-dd, or null when the text names no date")
            var dueDate: String?
            @Guide(description: "Priority 1 (urgent) to 4 (someday), null when unstated")
            var priority: Int?
            @Guide(description: "Topic labels, single lowercase words, no # prefix")
            var labels: [String]
        }

        @Generable
        struct GeneratedTaskList {
            @Guide(description: "Every concrete action item a busy professional would extract")
            var tasks: [GeneratedTask]
        }

        public func summarize(_ text: String) async throws -> String {
            let session = LanguageModelSession(
                instructions: "You summarize markdown notes in 2-4 tight sentences. No preamble, no headers."
            )
            let response = try await session.respond(to: "Summarize this note:\n\n\(text)")
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw AIProviderError.failed("empty summary") }
            return summary
        }

        public func extractActionItems(from text: String) async throws -> [AITask] {
            let session = LanguageModelSession(
                instructions: "You extract actionable to-do items from meeting notes and documents. Today is \(Self.today())."
            )
            let response = try await session.respond(
                to: "Extract the action items from this note:\n\n\(text)",
                generating: GeneratedTaskList.self
            )
            return response.content.tasks.map(Self.task(from:))
        }

        public func parseTask(_ input: String) async throws -> AITask {
            let session = LanguageModelSession(
                instructions: "You convert one natural-language sentence into a structured task. Today is \(Self.today())."
            )
            let response = try await session.respond(
                to: "Convert to a task: \(input)",
                generating: GeneratedTask.self
            )
            return Self.task(from: response.content)
        }

        static func task(from generated: GeneratedTask) -> AITask {
            AITask(
                text: generated.text,
                dueDate: generated.dueDate,
                priority: generated.priority.map { min(max($0, 1), 4) },
                labels: generated.labels.map { $0.lowercased() }
            )
        }

        static func today() -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date())
        }
    }
#endif

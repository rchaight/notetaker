import Foundation

/// Homelab tier: an Ollama server handles what the on-device model can't —
/// long documents, transcript cleanup, heavier reasoning. Only the URL and
/// model name are configuration; note content goes to the user's own
/// hardware and nowhere else.
public struct OllamaProvider: AIProvider {
    public let name: String

    let baseURL: URL
    let model: String
    let session: URLSession

    public init(baseURL: URL, model: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.model = model
        name = "Ollama (\(model))"
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Ollama comfortably takes long inputs; treat as effectively unbounded
    /// for router purposes.
    public var contextLimit: Int? {
        nil
    }

    public func isAvailable() async -> Bool {
        await !((try? listModels()) ?? []).isEmpty
    }

    /// GET /api/tags — availability probe + model picker source.
    public func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { throw AIProviderError.unavailable("no Ollama at \(baseURL.absoluteString)") }
        return models.compactMap { $0["name"] as? String }
    }

    public func summarize(_ text: String) async throws -> String {
        let content = try await chat(
            system: "You summarize markdown notes in 2-5 tight sentences. No preamble, no headers, no bullet lists.",
            user: "Summarize this note:\n\n\(text)",
            schema: nil
        )
        let summary = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw AIProviderError.failed("empty summary") }
        return summary
    }

    public func extractActionItems(from text: String) async throws -> [AITask] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "dueDate": ["type": ["string", "null"]],
                            "priority": ["type": ["integer", "null"]],
                            "labels": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["text", "labels"],
                    ],
                ],
            ],
            "required": ["tasks"],
        ]
        let content = try await chat(
            system: "You extract actionable to-do items from notes. Dates as yyyy-MM-dd or null; priority 1 (urgent) to 4 or null; labels are lowercase single words. Today is \(Self.today()).",
            user: "Extract the action items from this note:\n\n\(text)",
            schema: schema
        )
        struct Payload: Decodable {
            struct Task: Decodable {
                let text: String
                let dueDate: String?
                let priority: Int?
                let labels: [String]
            }

            let tasks: [Task]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(content.utf8)) else {
            throw AIProviderError.failed("Ollama returned unparseable JSON")
        }
        return payload.tasks.map {
            AITask(
                text: $0.text,
                dueDate: $0.dueDate,
                priority: $0.priority.map { min(max($0, 1), 4) },
                labels: $0.labels.map { $0.lowercased() }
            )
        }
    }

    public func parseTask(_ input: String) async throws -> AITask {
        let items = try await extractActionItems(from: input)
        guard let first = items.first else { throw AIProviderError.failed("no task recognized") }
        return first
    }

    // MARK: - Plumbing

    public func suggestTagMerges(tags: [(tag: String, count: Int)]) async throws -> [TagMerge] {
        let heuristic = TagCuration.heuristicMerges(tags: tags)
        let inventory = tags.map { "\($0.tag) (\($0.count))" }.joined(separator: ", ")
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "merges": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "from": ["type": "array", "items": ["type": "string"]],
                            "into": ["type": "string"],
                            "reason": ["type": "string"],
                        ],
                        "required": ["from", "into", "reason"],
                    ],
                ],
            ],
            "required": ["merges"],
        ]
        let raw = try await chat(
            system: "You consolidate note tags. Suggest merging semantically duplicate or near-duplicate tags into the most-used variant. Only reference tags from the provided list. Fewer, higher-confidence suggestions beat many speculative ones.",
            user: "Tags with usage counts: \(inventory)",
            schema: schema
        )
        struct Response: Codable {
            let merges: [TagMerge]
        }
        let ai = (try? JSONDecoder().decode(Response.self, from: Data(raw.utf8)))?.merges ?? []
        // Model output is UNTRUSTED: validate, then union with heuristics.
        let validated = TagCuration.validated(ai, against: tags)
        let heuristicIds = Set(heuristic.map(\.id))
        return heuristic + validated.filter { !heuristicIds.contains($0.id) }
    }

    private func chat(system: String, user: String, schema: [String: Any]?) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let schema {
            body["format"] = schema
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIProviderError.failed("Ollama HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw AIProviderError.failed("unexpected Ollama response shape") }
        return content
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

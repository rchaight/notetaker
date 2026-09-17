import Foundation

/// A self-hosted `erikvl87/languagetool` server (homelab-only topology —
/// same trust model as `OllamaProvider`: only the URL is configuration,
/// note text goes to the user's own hardware and nowhere else). Talks to
/// LanguageTool's HTTP API using the annotated-text `data` parameter so
/// excluded ranges are sent as `markup` rather than plain text — see
/// `AnnotatedText` for why that keeps every returned offset already
/// aligned to the ORIGINAL text with no coordinate conversion.
public struct LanguageToolProvider: GrammarProvider {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    /// POST {base}/v2/check. `language` defaults to "auto" — LanguageTool
    /// detects the language itself rather than assuming English.
    public func check(_ text: String, excluding: [NSRange], language: String?) async throws -> [GrammarMatch] {
        guard !text.isEmpty else { return [] }
        let segments = AnnotatedText.build(text: text, excluding: excluding)
        let dataParam = AnnotatedText.json(for: segments)
        let body = "data=\(Self.formEncode(dataParam))&language=\(Self.formEncode(language ?? "auto"))"

        var request = URLRequest(url: baseURL.appendingPathComponent("v2/check"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw GrammarError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw GrammarError.badResponse("HTTP \(http.statusCode)")
        }
        let decoded = try Self.decodeMatches(data, textLength: (text as NSString).length)
        return Self.dropping(decoded, touching: excluding)
    }

    /// Last line of defense. LanguageTool drops markup from the text it
    /// analyzes, so a rule can span the GAP where a token was: its
    /// whitespace rule sees the double space around `#tag`, and the range
    /// it reports in the original text covers the tag itself — one Apply
    /// would delete it (critic-caught). Nothing that touches an excluded
    /// span is ever surfaced.
    static func dropping(_ matches: [GrammarMatch], touching excluded: [NSRange]) -> [GrammarMatch] {
        matches.filter { match in
            !excluded.contains { NSIntersectionRange($0, match.range).length > 0 }
        }
    }

    /// GET {base}/v2/languages — Settings' "Test connection" probe and the
    /// preferred-language picker's source.
    public func listLanguages() async throws -> [Language] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/languages"))
        request.httpMethod = "GET"

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw GrammarError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw GrammarError.badResponse("HTTP \(http.statusCode)")
        }
        struct Entry: Decodable {
            let name: String
            let longCode: String?
            let code: String
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            throw GrammarError.badResponse("unexpected /v2/languages shape")
        }
        return entries.map { Language(id: $0.longCode ?? $0.code, name: $0.name) }
    }

    public struct Language: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
    }

    // MARK: - Plumbing

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await Self.withTimeout(8) {
                try await session.data(for: request)
            }
        } catch let error as GrammarError {
            throw error
        } catch {
            throw GrammarError.unreachable("\(baseURL.absoluteString): \(error.localizedDescription)")
        }
    }

    /// Same task-race pattern the app's Ollama calls use (`withTimeout` in
    /// `VaultIndexService`), but throwing: a slow/unreachable homelab must
    /// time out in 8s rather than hang the panel, while a real failure
    /// (DNS, connection refused) still surfaces as its own error rather
    /// than being flattened into "timeout".
    static func withTimeout<T: Sendable>(
        _ seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw GrammarError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw GrammarError.timeout
            }
            return result
        }
    }

    /// Decodes LanguageTool's real response shape
    /// (`matches[].{offset,length,message,shortMessage,replacements[].value,
    /// rule.id,rule.category.id}`) and bounds-checks every range against
    /// `textLength` — a malformed/drifted response drops the offending
    /// match instead of producing an out-of-bounds NSRange or crashing.
    static func decodeMatches(_ data: Data, textLength: Int) throws -> [GrammarMatch] {
        struct Response: Decodable {
            struct Match: Decodable {
                struct Replacement: Decodable { let value: String }
                struct Rule: Decodable {
                    struct Category: Decodable { let id: String }
                    let id: String
                    let category: Category
                }

                let offset: Int
                let length: Int
                let message: String
                let shortMessage: String?
                let replacements: [Replacement]
                let rule: Rule
            }

            let matches: [Match]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GrammarError.badResponse("unexpected LanguageTool response shape")
        }
        return decoded.matches.compactMap { match in
            guard match.offset >= 0, match.length >= 0,
                  match.offset + match.length <= textLength
            else { return nil }
            return GrammarMatch(
                range: NSRange(location: match.offset, length: match.length),
                message: match.message,
                shortMessage: match.shortMessage ?? "",
                replacements: match.replacements.map(\.value),
                ruleId: match.rule.id,
                category: match.rule.category.id
            )
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

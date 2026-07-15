@testable import AIKit
import Foundation
import Testing

#if canImport(FoundationModels)
    import FoundationModels
#endif

struct NoneProviderTests {
    let provider = NoneProvider()

    @Test func alwaysAvailable() async {
        #expect(await provider.isAvailable())
    }

    @Test func parseTaskUsesTheOneGrammar() async throws {
        let task = try await provider.parseTask("email dean tomorrow p1 #admin")
        #expect(task.priority == 1)
        #expect(task.labels == ["admin"])
        #expect(task.dueDate != nil)
        #expect(task.markdownLine.hasPrefix("- [ ] email dean"))
    }

    @Test func extractFindsActionLines() async throws {
        let note = """
        # Meeting
        Discussed the budget at length.
        TODO: send revised numbers to the provost
        We should schedule the follow-up for next month.
        - [ ] already a task, must be ignored
        """
        let tasks = try await provider.extractActionItems(from: note)
        #expect(tasks.count == 2)
        #expect(tasks[0].text.contains("send revised numbers"))
        #expect(tasks[1].text.lowercased().contains("schedule the follow-up"))
    }

    @Test func summarizeIsExtractive() async throws {
        let text = "The committee approved the new curriculum after extended discussion. Implementation begins in the fall semester with three pilot sections. Assessment data will be reviewed quarterly by the faculty senate. Nothing else happened."
        let summary = try await provider.summarize(text)
        #expect(summary.contains("committee approved"))
        #expect(summary.split(separator: ".").count <= 4)
    }

    @Test func markdownLineCarriesEverything() {
        let task = AITask(text: "review grant", dueDate: "2026-08-01", priority: 2, labels: ["research", "grants"])
        #expect(task.markdownLine == "- [ ] review grant >2026-08-01 !p2 #research #grants")
    }
}

struct AIRouterTests {
    struct StubProvider: AIProvider {
        let name: String
        let available: Bool
        func isAvailable() async -> Bool {
            available
        }

        func summarize(_: String) async throws -> String {
            "stub summary from \(name)"
        }

        func extractActionItems(from _: String) async throws -> [AITask] {
            []
        }

        func parseTask(_: String) async throws -> AITask {
            AITask(text: "x", dueDate: nil, priority: nil, labels: [])
        }
    }

    @Test func prefersFirstAvailable() async throws {
        let router = AIRouter(providers: [
            StubProvider(name: "first", available: false),
            StubProvider(name: "second", available: true),
        ])
        let (_, provider) = try await router.summarize("text")
        #expect(provider == "second")
    }

    @Test func fallsBackToNone() async {
        let router = AIRouter(providers: [StubProvider(name: "off", available: false)])
        let provider = await router.activeProvider()
        #expect(provider.name == "Basic (no AI)")
    }
}

#if canImport(FoundationModels)
    /// Live on-device model tests — run only where Apple Intelligence is
    /// actually available (they exercise the REAL model).
    struct FoundationModelsLiveTests {
        /// Live generation runs only when explicitly requested — the model is
        /// heavyweight and some test-host contexts crash the beta adapter.
        static var modelAvailable: Bool {
            ProcessInfo.processInfo.environment["NOTETAKER_FMF_LIVE"] == "1"
                && SystemLanguageModel.default.availability == .available
        }

        @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(2)))
        func parsesNaturalTask() async throws {
            let task = try await FoundationModelsProvider()
                .parseTask("remind me to call Bob about the syllabus on Friday, it's urgent")
            #expect(task.text.lowercased().contains("bob"))
            #expect(task.dueDate?.hasPrefix("20") == true, "resolved a concrete date: \(task.dueDate ?? "nil")")
        }

        @Test(.enabled(if: modelAvailable), .timeLimit(.minutes(2)))
        func summarizesShortNote() async throws {
            let summary = try await FoundationModelsProvider().summarize(
                "The pharmacy curriculum committee met today. We agreed to revise PHAR 7315 against the COEPA 2022 standards, with drafts due at the end of August. Dr. Chen will lead the rubric alignment."
            )
            #expect(summary.count > 20)
            #expect(summary.count < 800)
        }
    }
#endif

/// URLProtocol stub for the Ollama tier.
final class OllamaStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct OllamaProviderTests {
    private func makeProvider() -> OllamaProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStubProtocol.self]
        return OllamaProvider(
            baseURL: URL(string: "http://homelab.test:11434")!,
            model: "qwen3",
            session: URLSession(configuration: configuration)
        )
    }

    @Test func listsModelsAndAvailability() async throws {
        OllamaStubProtocol.handler = { _ in
            (200, Data(##"{"models":[{"name":"qwen3"},{"name":"gemma3:12b"}]}"##.utf8))
        }
        let models = try await makeProvider().listModels()
        #expect(models == ["qwen3", "gemma3:12b"])
        #expect(await makeProvider().isAvailable())
    }

    @Test func unreachableMeansUnavailable() async {
        OllamaStubProtocol.handler = { _ in (503, Data()) }
        #expect(await !(makeProvider().isAvailable()))
    }

    @Test func summarizeParsesChatResponse() async throws {
        OllamaStubProtocol.handler = { request in
            if request.url?.path.hasSuffix("api/tags") == true {
                return (200, Data(##"{"models":[{"name":"qwen3"}]}"##.utf8))
            }
            return (200, Data(##"{"message":{"role":"assistant","content":"A tight summary."}}"##.utf8))
        }
        let summary = try await makeProvider().summarize("long note text")
        #expect(summary == "A tight summary.")
    }

    @Test func extractDecodesStructuredJSON() async throws {
        OllamaStubProtocol.handler = { _ in
            let content = ##"{\"tasks\":[{\"text\":\"send agenda\",\"dueDate\":\"2026-07-15\",\"priority\":2,\"labels\":[\"admin\"]}]}"##
            return (200, Data(##"{"message":{"content":""##.utf8) + Data(content.utf8) + Data(##""}}"##.utf8))
        }
        let tasks = try await makeProvider().extractActionItems(from: "note")
        #expect(tasks == [AITask(text: "send agenda", dueDate: "2026-07-15", priority: 2, labels: ["admin"])])
    }
}

struct SizeAwareRoutingTests {
    struct Windowed: AIProvider {
        let name: String
        let limit: Int?
        var contextLimit: Int? {
            limit
        }

        func isAvailable() async -> Bool {
            true
        }

        func summarize(_: String) async throws -> String {
            name
        }

        func extractActionItems(from _: String) async throws -> [AITask] {
            []
        }

        func parseTask(_: String) async throws -> AITask {
            AITask(text: "x", dueDate: nil, priority: nil, labels: [])
        }
    }

    @Test func longInputSkipsSmallWindow() async throws {
        let router = AIRouter(providers: [
            Windowed(name: "small", limit: 100),
            Windowed(name: "big", limit: nil),
        ])
        let short = try await router.summarize("short note")
        #expect(short.provider == "small")
        let long = try await router.summarize(String(repeating: "word ", count: 500))
        #expect(long.provider == "big")
    }
}

struct EmbeddingChunkerTests {
    @Test func groupsParagraphsUnderLimit() {
        let body = "First paragraph.\n\nSecond paragraph.\n\n" + String(repeating: "x", count: 900)
        let chunks = EmbeddingChunker.chunks(from: body, maxLength: 100)
        #expect(chunks.count >= 10, "oversized paragraph hard-splits")
        #expect(chunks[0].contains("First paragraph"))
        #expect(chunks.allSatisfy { $0.count <= 100 })
    }

    @Test func emptyBodyYieldsNoChunks() {
        #expect(EmbeddingChunker.chunks(from: "\n\n  \n").isEmpty)
    }
}

struct AppleEmbeddingLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil), .timeLimit(.minutes(3)))
    func embedsAndRanksByMeaning() async throws {
        let provider = AppleEmbeddingProvider()
        guard await provider.isAvailable() else { return } // assets absent: skip silently
        let vectors = try await provider.embed([
            "the committee approved the pharmacy curriculum",
            "students take medication therapy courses",
            "my car needs an oil change",
        ])
        #expect(vectors.count == 3)
        #expect(vectors[0].count == vectors[1].count)
        func cosine(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).map(*)
                .reduce(0, +) /
                (a.map { $0 * $0 }.reduce(0, +).squareRoot() * b.map { $0 * $0 }.reduce(0, +).squareRoot())
        }
        let related = cosine(vectors[0], vectors[1])
        let unrelated = cosine(vectors[0], vectors[2])
        #expect(related > unrelated, "curriculum topics must outrank car maintenance (\(related) vs \(unrelated))")
    }
}

struct TagCurationTests {
    @Test func detectsCasePluralAndSeparatorVariants() {
        let merges = TagCuration.heuristicMerges(tags: [
            ("project", 10), ("Projects", 2), ("meeting-notes", 5),
            ("meeting_notes", 1), ("budget", 3),
        ])
        #expect(merges.contains { $0.from == ["Projects"] && $0.into == "project" })
        #expect(merges.contains { $0.from == ["meeting_notes"] && $0.into == "meeting-notes" })
        #expect(!merges.contains { $0.into == "budget" || $0.from.contains("budget") })
    }

    @Test func higherCountWins() {
        let merges = TagCuration.heuristicMerges(tags: [("Work", 1), ("work", 9)])
        #expect(merges == [TagMerge(from: ["Work"], into: "work", reason: "case variant")])
    }

    @Test func validationDropsHallucinatedTags() {
        let tags: [(String, Int)] = [("real", 2), ("also", 1)]
        let merges = [
            TagMerge(from: ["ghost"], into: "real", reason: "x"),
            TagMerge(from: ["also"], into: "imaginary", reason: "x"),
            TagMerge(from: ["also", "ghost"], into: "real", reason: "x"),
            TagMerge(from: ["real"], into: "real", reason: "self"),
        ]
        let valid = TagCuration.validated(merges, against: tags)
        #expect(valid == [TagMerge(from: ["also"], into: "real", reason: "x")])
    }
}

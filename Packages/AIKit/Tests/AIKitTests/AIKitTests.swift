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

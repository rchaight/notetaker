import Foundation
import MCP
@testable import MCPKit
import Testing

/// Helpers for poking at the `Value` payloads the tools return.
extension Value {
    subscript(key: String) -> Value? {
        objectValue?[key]
    }

    var strings: [String] {
        arrayValue?.compactMap(\.stringValue) ?? []
    }
}

struct VaultServiceTests {
    // MARK: - vault_overview

    @Test func overviewReadsContextFilesAndCountsNotes() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()

        let overview = fixture.service(withIndex: true).vaultOverview()
        #expect(overview["source"]?.stringValue == "index")
        #expect(overview["claude_md"]?.stringValue?.contains("_index.md") == true)
        #expect(overview["index_md"]?.stringValue?.contains("📁 Work") == true)
        // 5 notes; the two _index.md files are machinery, not notes.
        #expect(overview["note_count"]?.intValue == 5)
        #expect(overview["vault_root"]?.stringValue == fixture.root.path)
    }

    @Test func overviewFallsBackToScanWithoutIndex() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }

        let overview = fixture.service(withIndex: false).vaultOverview()
        #expect(overview["source"]?.stringValue == "scan")
        #expect(overview["note_count"]?.intValue == 5)
    }

    @Test func overviewSaysWhyTheIndexIsMissing() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        // Point at an index file that isn't there — the app closed, deleted,
        // or never built it.
        let location = VaultLocation(
            root: fixture.root, indexPath: fixture.indexPath, origin: .argument
        )
        let service = VaultService(location: location, embeddings: StubEmbeddings())
        #expect(service.indexStatus.hasPrefix("unavailable"))
        #expect(service.vaultOverview()["source"]?.stringValue == "scan")
    }

    // MARK: - list_folder

    @Test func listFolderPrefersIndexFileAndFlagsLockedNotes() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }

        let listing = try fixture.service(withIndex: false).listFolder(path: "Work")
        #expect(listing["index_md"]?.stringValue?.contains("[Curriculum]") == true)
        let notes = listing["notes"]?.arrayValue ?? []
        #expect(notes.count == 2)
        let locked = notes.first { $0["path"]?.stringValue == "Work/Locked.md" }
        #expect(locked?["locked"]?.boolValue == true)
        let open = notes.first { $0["path"]?.stringValue == "Work/Curriculum.md" }
        #expect(open?["locked"]?.boolValue == false)
    }

    @Test func listFolderComputesAListingWhenNoIndexFileExists() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }

        let listing = try fixture.service(withIndex: false).listFolder(path: "Daily")
        #expect(listing["index_md"] == nil)
        #expect(listing["listing"]?.stringValue?.contains("[2026-08-20](Daily/2026-08-20.md)") == true)
    }

    @Test func listFolderRefusesToLeaveTheVault() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        #expect(throws: VaultReadError.self) {
            _ = try fixture.service(withIndex: false).listFolder(path: "../..")
        }
    }

    // MARK: - read_note

    @Test func readNoteReturnsFrontmatterAndBody() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }

        let note = try await fixture.service(withIndex: false).readNote(path: "Work/Curriculum")
        #expect(note["locked"]?.boolValue == false)
        #expect(note["title"]?.stringValue == "Curriculum")
        #expect(note["frontmatter"]?["area"]?.stringValue == "Curriculum")
        #expect(note["content"]?.stringValue?.contains("spiral structure") == true)
    }

    @Test func readNoteRedactsLockedNotes() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }

        let note = try await fixture.service(withIndex: false).readNote(path: "Work/Locked.md")
        #expect(note["locked"]?.boolValue == true)
        #expect(note["title"]?.stringValue == "Locked")
        #expect(note["content"] == nil)
        #expect(note["frontmatter"] == nil)
        #expect(NotetakerMCPServer.json(note).contains("ciphertext") == false)
    }

    @Test func readNoteReportsMissingNotes() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        await #expect(throws: VaultReadError.self) {
            _ = try await fixture.service(withIndex: false).readNote(path: "Nope.md")
        }
    }

    // MARK: - search

    @Test func keywordSearchUsesTheIndex() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()

        let results = await fixture.service(withIndex: true).search(query: "spiral", mode: .keyword)
        #expect(results["source"]?.stringValue == "index")
        #expect(results["results"]?.arrayValue?.first?["path"]?.stringValue == "Work/Curriculum.md")
        #expect(results["results"]?.arrayValue?.first?["snippet"]?.stringValue?.contains("spiral") == true)
    }

    @Test func hybridSearchAddsSemanticMatches() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        let embeddings = StubEmbeddings()
        try fixture.buildIndex(embeddings: embeddings)

        // "pharmacology" is in the body of Curriculum.md, so both halves
        // should agree on it and mark the hit as matched by each.
        let results = await fixture.service(withIndex: true, embeddings: embeddings)
            .search(query: "pharmacology", mode: .hybrid)
        #expect(results["semantic"]?.boolValue == true)
        let top = results["results"]?.arrayValue?.first
        #expect(top?["path"]?.stringValue == "Work/Curriculum.md")
        #expect(top?["matched_by"]?.strings.contains("semantic") == true)
    }

    @Test func searchStaysKeywordOnlyWhenEmbeddingsAreUnavailable() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()
        var embeddings = StubEmbeddings()
        embeddings.available = false

        let results = await fixture.service(withIndex: true, embeddings: embeddings)
            .search(query: "spiral", mode: .hybrid)
        #expect(results["semantic"]?.boolValue == false)
        #expect(results["source"]?.stringValue == "index")
        #expect(results["results"]?.arrayValue?.isEmpty == false)
    }

    @Test func searchFallsBackToScanningTheFiles() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }

        let results = await fixture.service(withIndex: false).search(query: "spiral")
        #expect(results["source"]?.stringValue == "scan")
        #expect(results["results"]?.arrayValue?.first?["path"]?.stringValue == "Work/Curriculum.md")
    }

    @Test func searchNeverQuotesALockedNote() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        let service = fixture.service(withIndex: false)

        // The note matches by name, so it IS a result — with a title and
        // nothing else.
        let byName = await service.search(query: "locked", limit: 10)
        let hit = byName["results"]?.arrayValue?.first { $0["path"]?.stringValue == "Work/Locked.md" }
        #expect(hit != nil)
        #expect(hit?["locked"]?.boolValue == true)
        #expect(hit?["snippet"] == nil)

        // Its ciphertext line happens to contain "pharmacology"; a scan must
        // never match on, or quote, the encrypted body.
        let byBody = await service.search(query: "pharmacology", limit: 10)
        #expect(NotetakerMCPServer.json(byBody).contains("ciphertext") == false)
        #expect(byBody["results"]?.arrayValue?.contains { $0["path"]?.stringValue == "Work/Locked.md" } != true)
    }

    @Test func searchSurvivesPunctuationInTheQuery() async throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()

        // Raw FTS5 would choke on these; the terms are extracted first.
        let results = await fixture.service(withIndex: true)
            .search(query: "\"spiral\" AND (curriculum -- ?", mode: .keyword)
        #expect(results["results"]?.arrayValue?.isEmpty == false)
    }

    @Test func snippetsAnchorOnTheQueryOrYieldToTheChunk() {
        #expect(VaultService.snippet(in: "a spiral curriculum", terms: ["spiral"])?.contains("spiral") == true)
        // No query word in the body: the caller quotes the matched embedding
        // chunk instead of an arbitrary prefix.
        #expect(VaultService.snippet(in: "nothing relevant here", terms: ["pharmacology"]) == nil)
    }

    // MARK: - tasks

    @Test func tasksComeFromTheIndexWithTokensParsed() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()

        let payload = fixture.service(withIndex: true).tasks(.init())
        #expect(payload["source"]?.stringValue == "index")
        let tasks = payload["tasks"]?.arrayValue ?? []
        #expect(tasks.count == 3) // the completed one is excluded
        let first = tasks.first
        #expect(first?["text"]?.stringValue == "book the accreditation site visit #accreditation")
        #expect(first?["priority"]?.intValue == 1)
        #expect(first?["due"]?.stringValue == "2026-08-25")
        #expect(first?["assignee"]?.stringValue == "dana")
        #expect(first?["tags"]?.strings == ["accreditation"])
        #expect(first?["path"]?.stringValue == "Inbox.md")
    }

    @Test func tasksFilterByAssigneeKindAndLabel() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()
        let service = fixture.service(withIndex: true)

        #expect(service.tasks(.init(assignee: "dana"))["count"]?.intValue == 2)
        #expect(service.tasks(.init(kind: "waiting"))["count"]?.intValue == 1)
        #expect(service.tasks(.init(label: "curriculum"))["count"]?.intValue == 1)
        #expect(service.tasks(.init(includeCompleted: true))["count"]?.intValue == 4)
    }

    @Test func tasksFilterByDueHorizon() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()
        let today = try #require(VaultService.day.date(from: "2026-08-20"))

        let soon = fixture.service(withIndex: true).tasks(.init(dueWithinDays: 3), today: today)
        #expect(soon["count"]?.intValue == 1) // only the 08-22 one
        let month = fixture.service(withIndex: true).tasks(.init(dueWithinDays: 60), today: today)
        #expect(month["count"]?.intValue == 3)
    }

    @Test func tasksFallBackToScanningAndAgreeWithTheIndex() throws {
        let fixture = try VaultFixture()
        defer { fixture.cleanUp() }
        try fixture.buildIndex()

        let scanned = fixture.service(withIndex: false).tasks(.init())
        #expect(scanned["source"]?.stringValue == "scan")
        let indexed = fixture.service(withIndex: true).tasks(.init())
        #expect(scanned["tasks"] == indexed["tasks"])
    }
}

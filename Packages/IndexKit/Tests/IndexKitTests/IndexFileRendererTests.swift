import Foundation
@testable import IndexKit
import Testing

struct IndexFileRendererTests {
    private func entry(
        noteId: String, title: String? = nil, modifiedAt: Date? = nil,
        openTaskCount: Int = 0, tags: [String] = [], isLocked: Bool = false,
        summary: String? = nil
    ) -> IndexFileRenderer.NoteEntry {
        IndexFileRenderer.NoteEntry(
            noteId: noteId,
            title: title ?? URL(fileURLWithPath: noteId).deletingPathExtension().lastPathComponent,
            modifiedAt: modifiedAt, openTaskCount: openTaskCount, tags: tags,
            isLocked: isLocked, summary: summary
        )
    }

    @Test func headerIsAlwaysFirstLine() {
        let rendered = IndexFileRenderer.render(folderPath: "", notes: [], subfolders: [])
        #expect(rendered.hasPrefix(IndexFileRenderer.header))
    }

    @Test func rootFolderNameIsVaultRoot() {
        let rendered = IndexFileRenderer.render(folderPath: "", notes: [], subfolders: [])
        #expect(rendered.contains("# Index — Vault root"))
    }

    @Test func nestedFolderNameIsLastComponent() {
        let rendered = IndexFileRenderer.render(folderPath: "Projects/Alpha", notes: [], subfolders: [])
        #expect(rendered.contains("# Index — Alpha"))
    }

    @Test func emptyFolderHasNoListSections() {
        let rendered = IndexFileRenderer.render(folderPath: "Empty", notes: [], subfolders: [])
        #expect(rendered == IndexFileRenderer.header + "\n\n# Index — Empty\n")
    }

    @Test func subfoldersSortedAToZBeforeNotes() {
        let rendered = IndexFileRenderer.render(
            folderPath: "",
            notes: [entry(noteId: "b.md")],
            subfolders: ["Zebra", "apple"]
        )
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let subfolderLines = lines.filter { $0.hasPrefix("- 📁") }
        #expect(subfolderLines == [
            "- 📁 [apple/](apple/_index.md)",
            "- 📁 [Zebra/](Zebra/_index.md)",
        ])
    }

    @Test func notesSortedAToZByFilename() {
        let rendered = IndexFileRenderer.render(
            folderPath: "",
            notes: [entry(noteId: "Banana.md"), entry(noteId: "apple.md"), entry(noteId: "Cherry.md")],
            subfolders: []
        )
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let noteLines = lines.filter { $0.hasPrefix("- [") }
        #expect(noteLines[0].contains("apple.md"))
        #expect(noteLines[1].contains("Banana.md"))
        #expect(noteLines[2].contains("Cherry.md"))
    }

    @Test func lockedNoteOmitsLinkAndSummary() {
        let rendered = IndexFileRenderer.render(
            folderPath: "",
            notes: [entry(
                noteId: "Secret.md", title: "Secret", isLocked: true,
                summary: "should never appear"
            )],
            subfolders: []
        )
        #expect(rendered.contains("- 🔒 Secret — locked note"))
        #expect(!rendered.contains("should never appear"))
        #expect(!rendered.contains("[Secret]"))
    }

    @Test func fullLineAssemblesAllSegments() throws {
        // Local calendar day, matching the render-side formatter (no
        // explicit time zone — "modified" is a user-facing local date).
        var components = DateComponents(year: 2026, month: 7, day: 14, hour: 12)
        components.calendar = Calendar(identifier: .gregorian)
        let modified = try #require(components.date)
        let rendered = IndexFileRenderer.render(
            folderPath: "",
            notes: [entry(
                noteId: "Plan.md", title: "Plan", modifiedAt: modified,
                openTaskCount: 2, tags: ["b", "a"], summary: "A short summary."
            )],
            subfolders: []
        )
        #expect(rendered.contains(
            "- [Plan](Plan.md) — A short summary. · #a #b · 2 open tasks · 2026-07-14 modified"
        ))
    }

    @Test func singularOpenTaskWording() {
        let rendered = IndexFileRenderer.render(
            folderPath: "", notes: [entry(noteId: "One.md", openTaskCount: 1)], subfolders: []
        )
        #expect(rendered.contains("1 open task"))
        #expect(!rendered.contains("1 open tasks"))
    }

    @Test func omittedSegmentsDropTheirSeparator() {
        // No summary, no tags, no tasks, no modified date: bare link line.
        let rendered = IndexFileRenderer.render(
            folderPath: "", notes: [entry(noteId: "Bare.md", title: "Bare")], subfolders: []
        )
        #expect(rendered.contains("- [Bare](Bare.md)\n"))
        #expect(!rendered.contains("Bare](Bare.md) —"))
    }

    @Test func filenameWithSpacesIsURLEncoded() {
        let rendered = IndexFileRenderer.render(
            folderPath: "", notes: [entry(noteId: "My Note.md", title: "My Note")], subfolders: []
        )
        #expect(rendered.contains("[My Note](My%20Note.md)"))
    }

    @Test func subfolderNameWithSpacesIsURLEncoded() {
        let rendered = IndexFileRenderer.render(folderPath: "", notes: [], subfolders: ["My Folder"])
        #expect(rendered.contains("- 📁 [My Folder/](My%20Folder/_index.md)"))
    }

    @Test func summaryTruncatedTo120Chars() {
        // Truncation happens at extraction time (extractSummary); render()
        // trusts its precomputed NoteEntry.summary, matching driver usage.
        let long = String(repeating: "x", count: 200)
        let truncated = IndexFileRenderer.extractSummary(fromBody: long)
        let rendered = IndexFileRenderer.render(
            folderPath: "", notes: [entry(noteId: "Long.md", title: "Long", summary: truncated)],
            subfolders: []
        )
        #expect(rendered.contains(String(repeating: "x", count: 120) + "…"))
        #expect(!rendered.contains(String(repeating: "x", count: 121)))
    }

    // MARK: - extractSummary

    @Test func extractSummarySkipsHeadingsAndTasksAndBlankLines() {
        let body = """

        # Heading

        - [ ] a task
        - [x] a done task
        This is the summary line.
        More text after.
        """
        #expect(IndexFileRenderer.extractSummary(fromBody: body) == "This is the summary line.")
    }

    @Test func extractSummaryReturnsNilWhenNoEligibleLine() {
        let body = """
        # Only a heading
        - [ ] only a task
        """
        #expect(IndexFileRenderer.extractSummary(fromBody: body) == nil)
    }

    @Test func extractSummaryTruncatesLongLines() {
        let long = String(repeating: "y", count: 150)
        #expect(IndexFileRenderer.extractSummary(fromBody: long) == String(repeating: "y", count: 120) + "…")
    }
}

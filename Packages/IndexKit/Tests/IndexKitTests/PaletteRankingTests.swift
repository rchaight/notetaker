import Foundation
@testable import IndexKit
import Testing

struct PaletteRankingTests {
    private typealias Note = PaletteRanking.Note
    private typealias Command = (id: String, title: String, shortcut: String?)

    private func note(_ title: String, id: String? = nil, folder: String? = nil) -> Note {
        Note(id: id ?? "\(title).md", title: title, folder: folder)
    }

    private func command(_ id: String, _ title: String, shortcut: String? = nil) -> Command {
        (id: id, title: title, shortcut: shortcut)
    }

    @Test func exactBeatsPrefixBeatsWordPrefixBeatsSubstringBeatsSubsequence() throws {
        let exact = try #require(PaletteRanking.score(query: "plan", title: "Plan"))
        let prefix = try #require(PaletteRanking.score(query: "plan", title: "Planning"))
        let wordPrefix = try #require(PaletteRanking.score(query: "plan", title: "Deployment Plan"))
        let substring = try #require(PaletteRanking.score(query: "plan", title: "Airplane"))
        let subsequence = try #require(PaletteRanking.score(query: "plan", title: "Pxlxaxn"))
        #expect(exact > prefix)
        #expect(prefix > wordPrefix)
        #expect(wordPrefix > substring)
        #expect(substring > subsequence)
        #expect(exact == 1000)
        #expect(subsequence > 0)
    }

    @Test func shortQueryOrdersPlanDeploymentPlanSample() {
        let notes = [note("Sample"), note("Deployment Plan"), note("Plan")]
        let rows = PaletteRanking.rank(query: "pl", commands: [], notes: notes, recents: [])
        #expect(rows.map(\.title) == ["Plan", "Deployment Plan", "Sample"])
    }

    @Test func noMatchIsNil() {
        #expect(PaletteRanking.score(query: "zzz", title: "Plan") == nil)
        // Characters present but not in order is not a match.
        #expect(PaletteRanking.score(query: "nalp", title: "Plan") == nil)
        // A query longer than the title can't be a subsequence of it.
        #expect(PaletteRanking.score(query: "planning", title: "Plan") == nil)
        #expect(PaletteRanking.rank(query: "zzz", commands: [command("a", "Plan")], notes: [note("Plan")], recents: [])
            .isEmpty)
    }

    @Test func multiTokenRequiresEveryToken() throws {
        let both = try #require(PaletteRanking.score(query: "dep plan", title: "Deployment Plan"))
        // prefix 800 + word-prefix 600 - 15/10
        #expect(both == 1399)
        #expect(PaletteRanking.score(query: "plan dep", title: "Deployment Plan") == both, "token order is free")
        #expect(PaletteRanking.score(query: "dep zzz", title: "Deployment Plan") == nil)
        #expect(PaletteRanking.score(query: "  dep   plan ", title: "Deployment Plan") == both)
    }

    @Test func shorterTitleWinsTies() throws {
        let short = try #require(PaletteRanking.score(query: "plan", title: "Plan x"))
        let long = try #require(PaletteRanking.score(query: "plan", title: "Plan with a rather long title indeed"))
        #expect(short > long)
        let rows = PaletteRanking.rank(
            query: "plan", commands: [],
            notes: [note("Plan with a rather long title indeed"), note("Plan x")], recents: []
        )
        #expect(rows.map(\.title) == ["Plan x", "Plan with a rather long title indeed"])
    }

    @Test func equalScoresOrderByTitleThenId() {
        let notes = [
            note("Alpha Two", id: "b/Alpha Two.md"),
            note("alpha one", id: "z.md"),
            note("Alpha One", id: "a.md"),
        ]
        let rows = PaletteRanking.rank(query: "alpha", commands: [], notes: notes, recents: [])
        #expect(rows.map(\.id) == ["note:a.md", "note:z.md", "note:b/Alpha Two.md"])
    }

    @Test func recentsBonusReordersEqualScores() {
        let notes = [
            note("Alpha One", id: "one.md"),
            note("Alpha Two", id: "two.md"),
        ]
        let plain = PaletteRanking.rank(query: "alpha", commands: [], notes: notes, recents: [])
        #expect(plain.map(\.id) == ["note:one.md", "note:two.md"])

        let boosted = PaletteRanking.rank(query: "alpha", commands: [], notes: notes, recents: ["two.md"])
        #expect(boosted.map(\.id) == ["note:two.md", "note:one.md"])
        #expect(boosted[0].score == plain[1].score + 100)

        // Newer recents earn more: index 0 → +100, index 1 → +90.
        let ordered = PaletteRanking.rank(
            query: "alpha", commands: [], notes: notes, recents: ["one.md", "two.md"]
        )
        #expect(ordered.map(\.id) == ["note:one.md", "note:two.md"])
        #expect(ordered[0].score - plain[0].score == 100)
        #expect(ordered[1].score - plain[1].score == 90)
    }

    @Test func recentsBonusNeverOutranksAHigherTier() {
        let notes = [note("Plan", id: "plan.md"), note("Airplane notes", id: "air.md")]
        let rows = PaletteRanking.rank(query: "plan", commands: [], notes: notes, recents: ["air.md"])
        #expect(rows.map(\.id) == ["note:plan.md", "note:air.md"])
    }

    @Test func folderMatchEarnsSubstringCredit() {
        let notes = [
            note("Syllabus", id: "Courses/PHAR7315/Syllabus.md", folder: "Courses/PHAR7315"),
            note("Other", id: "Inbox/Other.md", folder: "Inbox"),
        ]
        let rows = PaletteRanking.rank(query: "phar7315 syl", commands: [], notes: notes, recents: [])
        #expect(rows.map(\.id) == ["note:Courses/PHAR7315/Syllabus.md"])
        // The folder alone is enough for a token, but every token still has to match somewhere.
        #expect(PaletteRanking.rank(query: "phar7315 zzz", commands: [], notes: notes, recents: []).isEmpty)
    }

    @Test func emptyQueryListsRecentsThenCommands() {
        let notes = (1 ... 7).map { note("Note \($0)", id: "n\($0).md", folder: "F") }
        let commands = (1 ... 10).map { command("c\($0)", "Command \($0)", shortcut: "⌘\($0)") }
        let recents = ["n3.md", "gone.md", "n1.md", "n2.md", "n3.md", "n4.md", "n5.md", "n6.md"]
        let rows = PaletteRanking.rank(query: "", commands: commands, notes: notes, recents: recents)

        // 5 recents in order (unknown and repeated ids skipped), then 8 commands in table order.
        #expect(rows.count == 13)
        #expect(rows.prefix(5).map(\.id) == ["note:n3.md", "note:n1.md", "note:n2.md", "note:n4.md", "note:n5.md"])
        #expect(rows.suffix(8).map(\.id) == (1 ... 8).map { "cmd:c\($0)" })
        #expect(rows.allSatisfy { $0.score == 0 })
        #expect(rows[0].subtitle == "F")
        #expect(rows[5].subtitle == "⌘1")
        #expect(PaletteRanking.rank(query: "   ", commands: commands, notes: notes, recents: []).count == 8)
    }

    @Test func commandAndNoteLimits() {
        let commands = (1 ... 12).map { command("c\($0)", "Item command \($0)") }
        let notes = (1 ... 20).map { note("Item note \($0)", id: "n\($0).md") }
        let rows = PaletteRanking.rank(query: "item", commands: commands, notes: notes, recents: [])
        #expect(rows.count == 16)
        let kinds = rows.map(\.kind)
        #expect(kinds.prefix(6).allSatisfy {
            if case .command = $0 {
                true
            } else {
                false
            }
        })
        #expect(kinds.suffix(10).allSatisfy {
            if case .note = $0 {
                true
            } else {
                false
            }
        })
        // The cut keeps the best-scoring rows, not the first ones in input order.
        let single = PaletteRanking.rank(
            query: "item note 20",
            commands: [], notes: notes, recents: []
        )
        #expect(single.first?.id == "note:n20.md")
    }

    @Test func commandsCarryShortcutAndKind() {
        let rows = PaletteRanking.rank(
            query: "new",
            commands: [command("newNote", "New Note", shortcut: "⌘N")],
            notes: [], recents: []
        )
        #expect(rows.count == 1)
        #expect(rows[0].id == "cmd:newNote")
        #expect(rows[0].kind == .command("newNote"))
        #expect(rows[0].subtitle == "⌘N")
    }

    @Test func bodyHitsExcludeListedIds() {
        let notes = (1 ... 9).map { note("Note \($0)", id: "n\($0).md", folder: "F") }
        let listed = PaletteRanking.rank(query: "note 1", commands: [], notes: notes, recents: [])
        #expect(listed.contains { $0.id == "note:n1.md" })

        let ids = ["n1.md", "n2.md", "stale.md", "n3.md", "n2.md", "n4.md", "n5.md", "n6.md", "n7.md"]
        let hits = PaletteRanking.bodyHits(ids, notes: notes, excluding: listed)
        // n1 is a title hit already; stale ids and repeats drop; capped at 5 in FTS order.
        #expect(!hits.contains { $0.id == "body:n1.md" })
        #expect(hits.map(\.id) == ["body:n2.md", "body:n3.md", "body:n4.md", "body:n5.md", "body:n6.md"])
        #expect(hits.count == 5)
        #expect(hits[0].kind == .bodyHit("n2.md"))
        #expect(hits[0].title == "Note 2")
        #expect(hits[0].subtitle == "F")
    }

    @Test func bodyHitsNeverRepeatEarlierBodyRows() {
        let notes = [note("A", id: "a.md"), note("B", id: "b.md")]
        let first = PaletteRanking.bodyHits(["a.md"], notes: notes, excluding: [])
        let second = PaletteRanking.bodyHits(["a.md", "b.md"], notes: notes, excluding: first)
        #expect(second.map(\.id) == ["body:b.md"])
    }

    @Test func foldsCaseAndDiacritics() {
        #expect(PaletteRanking.score(query: "resume", title: "Résumé") == 1000)
        #expect(PaletteRanking.score(query: "RESUME", title: "Résumé") != nil)
        #expect(PaletteRanking.score(query: "résumé", title: "resume draft") != nil)
        #expect(PaletteRanking.score(query: "ÄRZTE", title: "Kaffee") == nil)
        #expect(PaletteRanking.score(query: "arzte", title: "Ärzte") == 1000)
    }
}

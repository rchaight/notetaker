import Foundation
@testable import MarkdownKit
import Testing

/// The daily-note planner for Audio Transcribe's meeting notes (Audio
/// Transcribe spec 03). Every case is a synthetic string; nothing touches disk.
struct MeetingNotesInsertionTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    static let notesBody = """

    # Meeting Notes — 2026-11-12 0830 IPE Consult

    - **Generated:** 2026-11-12
    - **Summarizer:** Ollama (qwen3)

    ---

    ## Summary

    The group agreed on four IPE levels.
    Ramona drafts the definitions.

    ## Key Decisions

    - Four levels

    ## Action Items

    - [ ] Draft definitions for the four IPE levels. @Ramona ?waiting
    - [ ] Review the draft.
    - [x] Book the room

    """

    func note(
        title: String? = "IPE Consult",
        eventStart: String? = "2026-11-12T08:30:00-06:00",
        body: String = notesBody,
        copiesSummary: Bool = true
    ) -> MeetingNote {
        MeetingNote(
            link: "Meetings/Notes/2026-11-12 0830 IPE Consult.notes",
            title: title,
            eventStart: eventStart.map(Self.date),
            start: Self.date("2026-11-12T08:30:15-06:00"),
            body: body,
            copiesSummary: copiesSummary
        )
    }

    static let block = """
    [[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]
    The group agreed on four IPE levels.
    Ramona drafts the definitions.
    Action items: 2 open — see linked notes
    """

    /// What `NotesModel.defaultDailyTemplate` + `CalendarService.meetingsMarkdown` produce.
    static let daily = """
    # 2026-11-12
    Thursday, November 12, 2026

    # 8:30 AM–9:30 AM — IPE Consult


    # 1:00 PM–2:00 PM — Budget


    # To-Do This Week
    - email dean (due 2026-11-13) · Inbox

    # Continuous Efforts:


    # On the Horizon:


    """

    func inserted(_ text: String, _ note: MeetingNote) -> String? {
        guard case let .insert(result) = MeetingNotesInsertion.plan(dailyNote: text, note: note, calendar: calendar)
        else { return nil }
        return result
    }

    // MARK: Heading match

    @Test func exactHeadingMatchInsertsDirectlyUnderTheHeading() {
        let result = inserted(Self.daily, note())
        let expected = Self.daily.replacingOccurrences(
            of: "# 8:30 AM–9:30 AM — IPE Consult\n",
            with: "# 8:30 AM–9:30 AM — IPE Consult\n\(Self.block)\n"
        )
        #expect(result == expected)
    }

    @Test func titleMatchIsCaseInsensitiveAndTrimmed() {
        let daily = "# 2026-11-12\n\n#   8:30 AM–9:30 AM —   ipe consult  \n\n# To-Do This Week\n"
        let result = inserted(daily, note())
        #expect(result?.hasPrefix("# 2026-11-12\n\n#   8:30 AM–9:30 AM —   ipe consult  \n[[Meetings/") == true)
        #expect(result?.components(separatedBy: "# ").count == daily.components(separatedBy: "# ").count)
    }

    @Test func narrowNoBreakSpaceTimesStillMatch() {
        // macOS's short time style writes "8:30\u{202F}AM".
        let daily = "# 8:30\u{202F}AM–9:30\u{202F}AM — IPE Consult\n\n# 3:00\u{202F}PM–4:00\u{202F}PM — IPE Consult\n\n"
        let afternoon = note(eventStart: "2026-11-12T15:05:00-06:00")
        let result = inserted(daily, afternoon) ?? ""
        let lines = splitLines(result)
        #expect(lines[2] == "# 3:00\u{202F}PM–4:00\u{202F}PM — IPE Consult")
        #expect(lines[3] == "[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]")
    }

    @Test func duplicateTitlesResolveToTheNearestStartTime() throws {
        let daily = """
        # 2026-11-12

        # 8:00 AM–8:30 AM — Standup

        morning

        # 4:30 PM–5:00 PM — Standup

        evening

        """
        let late = note(title: "Standup", eventStart: "2026-11-12T16:30:00-06:00")
        let result = inserted(daily, late) ?? ""
        let lines = splitLines(result)
        let heading = try #require(lines.firstIndex(of: "# 4:30 PM–5:00 PM — Standup"))
        #expect(lines[heading + 1].hasPrefix("[[Meetings/"))
        #expect(try lines[#require(lines.firstIndex(of: "# 8:00 AM–8:30 AM — Standup")) + 1] == "")

        let early = note(title: "Standup", eventStart: "2026-11-12T08:05:00-06:00")
        let earlyLines = splitLines(inserted(daily, early) ?? "")
        #expect(try earlyLines[#require(earlyLines.firstIndex(of: "# 8:00 AM–8:30 AM — Standup")) + 1]
            .hasPrefix("[[Meetings/"))
    }

    @Test func duplicateTitlesWithoutEventStartUseTheFirst() {
        let daily = "# 8:00 AM–8:30 AM — Standup\n\n# 4:30 PM–5:00 PM — Standup\n\n"
        let result = inserted(daily, note(title: "Standup", eventStart: nil)) ?? ""
        #expect(splitLines(result)[1].hasPrefix("[[Meetings/"))
    }

    // MARK: No match: a new heading, three placements

    @Test func noMatchGoesAfterTheLastMeetingSection() {
        let result = inserted(Self.daily, note(title: "Hallway chat", eventStart: "2026-11-12T10:15:00-06:00"))
        let expected = Self.daily.replacingOccurrences(
            of: "# 1:00 PM–2:00 PM — Budget\n\n\n",
            with: "# 1:00 PM–2:00 PM — Budget\n\n\n# 10:15 AM — Hallway chat\n"
                + "[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]\n"
                + "The group agreed on four IPE levels.\nRamona drafts the definitions.\n"
                + "Action items: 2 open — see linked notes\n\n"
        )
        #expect(result == expected)
    }

    @Test func noMeetingHeadingsGoesBeforeToDoThisWeek() {
        let daily = "# 2026-11-12\nThursday\n\n# To-Do This Week\n- a thing\n"
        let result = inserted(daily, note(title: "Hallway chat", body: "## Summary\nShort.\n"))
        #expect(result == """
        # 2026-11-12
        Thursday

        # 8:30 AM — Hallway chat
        [[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]
        Short.

        # To-Do This Week
        - a thing

        """)
    }

    @Test func noMeetingsAndNoToDoGoesAtTheEnd() {
        let daily = "# 2026-11-12\nThursday\n"
        let result = inserted(daily, note(title: "Hallway chat", body: "## Summary\nShort.\n"))
        #expect(result == """
        # 2026-11-12
        Thursday

        # 8:30 AM — Hallway chat
        [[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]
        Short.


        """)
        // Without a final newline the file still ends cleanly.
        let bare = inserted("# 2026-11-12", note(title: nil, body: ""))
        #expect(bare == "# 2026-11-12\n\n# 8:30 AM — Meeting\n[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]\n")
    }

    @Test func noTitleCreatesAMeetingHeadingFromStartWhenThereIsNoEventStart() {
        // An untitled recording never matches, even a heading titled "Meeting".
        let daily = "# 9:00 AM–10:00 AM — Meeting\n\n# To-Do This Week\n"
        let result = inserted(daily, note(title: nil, eventStart: nil, body: "")) ?? ""
        #expect(splitLines(result) == [
            "# 9:00 AM–10:00 AM — Meeting",
            "",
            "# 8:30 AM — Meeting",
            "[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]",
            "",
            "# To-Do This Week",
            "",
        ])
    }

    @Test func allDayHeadingsCountAsMeetingSections() {
        let daily = "# 2026-11-12\n\n# All day — Retreat\n\n# To-Do This Week\n"
        let result = inserted(daily, note(title: "Hallway chat", body: "")) ?? ""
        #expect(splitLines(result) == [
            "# 2026-11-12", "", "# All day — Retreat", "",
            "# 8:30 AM — Hallway chat",
            "[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]",
            "",
            "# To-Do This Week", "",
        ])
        // ...and an all-day heading with the title matches like any other.
        let retreat = inserted(daily, note(title: "Retreat", body: "")) ?? ""
        #expect(splitLines(retreat)[3] == "[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]")
    }

    @Test func headingsInsideCodeFencesAndSubheadingsAreIgnored() {
        let daily = "# 2026-11-12\n```\n# 8:30 AM–9:30 AM — IPE Consult\n```\n## 8:30 AM — IPE Consult\n"
        let result = inserted(daily, note(body: "")) ?? ""
        #expect(result.hasSuffix(
            "## 8:30 AM — IPE Consult\n\n# 8:30 AM — IPE Consult\n[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]\n\n"
        ))
    }

    // MARK: Idempotence

    @Test func alreadyLinkedChangesNothing() throws {
        let once = try #require(inserted(Self.daily, note()))
        #expect(MeetingNotesInsertion.plan(dailyNote: once, note: note(), calendar: calendar) == .alreadyLinked)
        // A link the user wrote by title, with an alias, counts too.
        let byTitle = Self.daily + "\nsee [[2026-11-12 0830 IPE Consult.notes|the notes]]\n"
        #expect(MeetingNotesInsertion.plan(dailyNote: byTitle, note: note(), calendar: calendar) == .alreadyLinked)
    }

    @Test func plannerAppliedTwiceEqualsOnce() throws {
        for daily in [Self.daily, "# 2026-11-12\n", "", "# To-Do This Week\n"] {
            let once = try #require(inserted(daily, note()))
            let twice: String = switch MeetingNotesInsertion.plan(dailyNote: once, note: note(), calendar: calendar) {
            case .alreadyLinked, .unlinkable: once
            case let .insert(text): text
            }
            #expect(twice == once)
        }
    }

    @Test func aDifferentMeetingNoteIsNotLinked() {
        let daily = Self.daily + "\n[[Meetings/Notes/2026-11-11 0900 IPE Consult.notes]]\n"
        #expect(inserted(daily, note()) != nil)
    }

    @Test func aPathThatCannotBeALinkIsRefusedNotInsertedForever() {
        for link in ["Meetings/2026-11-12 0830 Team #3 sync.notes", "Meetings/A|B.notes", "Meetings/x]y.notes"] {
            let odd = MeetingNote(link: link, title: "IPE Consult", eventStart: nil, start: nil, body: "")
            #expect(MeetingNotesInsertion.plan(dailyNote: Self.daily, note: odd, calendar: calendar) == .unlinkable)
        }
    }

    // MARK: Block contents

    @Test func userTextUnderTheHeadingIsPreservedBelowTheBlock() {
        let daily = "# 8:30 AM–9:30 AM — IPE Consult\nmy own notes\n- [ ] my task\n\n# To-Do This Week\n"
        let result = inserted(daily, note())
        #expect(result ==
            "# 8:30 AM–9:30 AM — IPE Consult\n\(Self.block)\n\nmy own notes\n- [ ] my task\n\n# To-Do This Week\n")
    }

    @Test func notesWithoutASummaryInsertOnlyTheLinkAndCount() {
        let body = "## Action Items\n- [ ] one\n- [ ] two\n- [ ] three\n"
        let result = inserted("# 8:30 AM–9:30 AM — IPE Consult\n", note(body: body))
        #expect(result == """
        # 8:30 AM–9:30 AM — IPE Consult
        [[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]
        Action items: 3 open — see linked notes


        """)
    }

    @Test func actionItemCountCountsOnlyUncheckedLines() {
        #expect(MeetingNotesInsertion.openActionItemCount(in: Self.notesBody) == 2)
        #expect(MeetingNotesInsertion.openActionItemCount(in: "- [x] done\n- None\n* [ ] star\n  - [ ] nested\n") == 2)
        // None open: no count line at all.
        let result = inserted("# 8:30 AM–9:30 AM — IPE Consult\n", note(body: "## Summary\nDone.\n- [x] all done\n"))
        #expect(result ==
            "# 8:30 AM–9:30 AM — IPE Consult\n[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]\nDone.\n\n")
    }

    @Test func summaryTaskLinesAreNotCopied() {
        let body = "## Summary\n\nWe met.\n- [ ] stray task\n- a point\n\n### Detail\nmore\n\n## Next\nignored\n"
        #expect(MeetingNotesInsertion.summaryLines(of: body) == ["We met.", "- a point", "", "### Detail", "more"])
        #expect(MeetingNotesInsertion.summaryLines(of: "## Summary\n") == [])
        #expect(MeetingNotesInsertion.summaryLines(of: "# Summary\nnot level two\n") == [])
    }

    @Test func privateNotesGetTheLinkButNotTheSummary() {
        let result = inserted("# 8:30 AM–9:30 AM — IPE Consult\n", note(copiesSummary: false))
        #expect(result == """
        # 8:30 AM–9:30 AM — IPE Consult
        [[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]
        Action items: 2 open — see linked notes


        """)
    }

    @Test func crlfDailyNotesStayCRLF() {
        let daily = "# 2026-11-12\r\n\r\n# 8:30 AM–9:30 AM — IPE Consult\r\nmine\r\n"
        let result = inserted(daily, note(body: "## Summary\nShort.\n")) ?? ""
        #expect(result == "# 2026-11-12\r\n\r\n# 8:30 AM–9:30 AM — IPE Consult\r\n"
            + "[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]\r\nShort.\r\n\r\nmine\r\n")
    }

    @Test func frontmatterInTheDailyNoteIsSkipped() {
        let daily = "---\n# 8:30 AM–9:30 AM — IPE Consult\n---\n# 2026-11-12\n"
        let result = inserted(daily, note(body: "")) ?? ""
        #expect(result.hasPrefix(daily))
        #expect(result.hasSuffix("# 8:30 AM — IPE Consult\n[[Meetings/Notes/2026-11-12 0830 IPE Consult.notes]]\n\n"))
    }

    // MARK: Briefs (type: meeting-brief)

    static let briefLink = "Briefs/IPE Consult — 2026-11-12.brief"
    static let briefLine = "Brief: [[Briefs/IPE Consult — 2026-11-12.brief]]"

    func brief(
        title: String? = "IPE Consult",
        eventStart: String? = "2026-11-12T08:30:00-06:00",
        body: String = "## Last time\nBRIEF-BODY-MARKER\n- [ ] BRIEF-TASK-MARKER\n"
    ) -> MeetingNote {
        MeetingNote(
            kind: .brief,
            link: Self.briefLink,
            title: title,
            eventStart: eventStart.map(Self.date),
            start: nil,
            body: body
        )
    }

    @Test func briefIsOneLineUnderAnExactHeadingMatch() {
        let result = inserted(Self.daily, brief())
        let expected = Self.daily.replacingOccurrences(
            of: "# 8:30 AM–9:30 AM — IPE Consult\n",
            with: "# 8:30 AM–9:30 AM — IPE Consult\n\(Self.briefLine)\n"
        )
        #expect(result == expected)
    }

    @Test func briefWithNoMatchingHeadingGetsAHeadingByTheThreePlacementRules() {
        // After the last meeting section.
        let after = inserted(Self.daily, brief(title: "Hallway chat", eventStart: "2026-11-12T10:15:00-06:00")) ?? ""
        #expect(after
            .contains(
                "# 1:00 PM–2:00 PM — Budget\n\n\n# 10:15 AM — Hallway chat\n\(Self.briefLine)\n\n# To-Do This Week"
            ))
        // Before To-Do This Week when there are no meeting headings.
        let todo = inserted("# 2026-11-12\n\n# To-Do This Week\n- a\n", brief(title: nil)) ?? ""
        #expect(todo == "# 2026-11-12\n\n# 8:30 AM — Meeting\n\(Self.briefLine)\n\n# To-Do This Week\n- a\n")
        // At the end otherwise.
        let end = inserted("# 2026-11-12\n", brief()) ?? ""
        #expect(end == "# 2026-11-12\n\n# 8:30 AM — IPE Consult\n\(Self.briefLine)\n\n")
    }

    @Test func briefAlreadyLinkedChangesNothingAndAppliedTwiceEqualsOnce() throws {
        for daily in [Self.daily, "# 2026-11-12\n", "", "# To-Do This Week\n"] {
            let once = try #require(inserted(daily, brief()))
            #expect(MeetingNotesInsertion.plan(dailyNote: once, note: brief(), calendar: calendar) == .alreadyLinked)
        }
        // A link the user wrote by hand, anywhere, counts.
        let byHand = Self.daily + "\n[[\(Self.briefLink)|brief]]\n"
        #expect(MeetingNotesInsertion.plan(dailyNote: byHand, note: brief(), calendar: calendar) == .alreadyLinked)
    }

    @Test func briefBlockNeverContainsTheBriefBody() throws {
        let result = try #require(inserted(Self.daily, brief()))
        #expect(!result.contains("BRIEF-BODY-MARKER"))
        #expect(!result.contains("BRIEF-TASK-MARKER"))
        #expect(!result.contains("Last time"))
        #expect(MeetingNotesInsertion.blockLines(for: brief()) == [Self.briefLine])
        // Not even when the notes-style rules would copy a summary and count tasks.
        let summarised = brief(body: "## Summary\nBRIEF-BODY-MARKER\n- [ ] one\n")
        #expect(MeetingNotesInsertion.blockLines(for: summarised) == [Self.briefLine])
    }

    @Test func notesThenBriefAndBriefThenNotesBothSurviveUnderOneHeading() throws {
        let daily = "# 8:30 AM–9:30 AM — IPE Consult\nmy own notes\n\n# To-Do This Week\n"
        let notesFirst = try #require(inserted(daily, note()))
        let both = try #require(inserted(notesFirst, brief()))
        #expect(both ==
            "# 8:30 AM–9:30 AM — IPE Consult\n\(Self.briefLine)\n\n\(Self.block)\n\nmy own notes\n\n# To-Do This Week\n")

        let briefFirst = try #require(inserted(daily, brief()))
        #expect(briefFirst ==
            "# 8:30 AM–9:30 AM — IPE Consult\n\(Self.briefLine)\n\nmy own notes\n\n# To-Do This Week\n")
        let reversed = try #require(inserted(briefFirst, note()))
        #expect(reversed ==
            "# 8:30 AM–9:30 AM — IPE Consult\n\(Self.block)\n\n\(Self.briefLine)\n\nmy own notes\n\n# To-Do This Week\n")

        // Both are then recognised as linked, whichever order they went in.
        for text in [both, reversed] {
            #expect(MeetingNotesInsertion.plan(dailyNote: text, note: note(), calendar: calendar) == .alreadyLinked)
            #expect(MeetingNotesInsertion.plan(dailyNote: text, note: brief(), calendar: calendar) == .alreadyLinked)
        }
    }

    @Test func briefInACRLFDailyNoteStaysCRLF() {
        let daily = "# 2026-11-12\r\n\r\n# 8:30 AM–9:30 AM — IPE Consult\r\nmine\r\n"
        let result = inserted(daily, brief()) ?? ""
        #expect(result == "# 2026-11-12\r\n\r\n# 8:30 AM–9:30 AM — IPE Consult\r\n\(Self.briefLine)\r\n\r\nmine\r\n")
    }

    static let briefFile = """
    ---
    type: meeting-brief
    title: "IPE Consult"
    date: 2026-11-12
    event_start: 2026-11-12T08:30:00-06:00
    attendees: ["Ramona Example"]
    ---

    ## Last time
    BRIEF-BODY-MARKER

    """

    @Test func parsesABriefAndOnlyTheTwoKinds() {
        let parsed = MeetingNote.parse(noteId: "Briefs/IPE Consult — 2026-11-12.brief.md", source: Self.briefFile)
        #expect(parsed?.kind == .brief)
        #expect(parsed?.link == Self.briefLink)
        #expect(parsed?.title == "IPE Consult")
        #expect(parsed?.day == "2026-11-12")
        #expect(parsed?.eventStart == Self.date("2026-11-12T08:30:00-06:00"))
        #expect(MeetingNote.parse(noteId: "a.md", source: Self.notesFile)?.kind == .notes)
        for other in ["meeting-transcript", "meeting-briefing", "brief", "Meeting-Brief"] {
            let source = Self.briefFile.replacingOccurrences(of: "type: meeting-brief", with: "type: \(other)")
            #expect(MeetingNote.parse(noteId: "a.md", source: source) == nil)
        }
        // A parsed brief's block still carries none of its body.
        if let parsed {
            #expect(inserted("# 2026-11-12\n", parsed)?.contains("BRIEF-BODY-MARKER") == false)
        }
    }

    // MARK: Which days are worth linking

    @Test func notesAreLinkableFromSevenDaysAgoThroughToday() {
        let now = Self.date("2026-11-13T09:00:00-06:00")
        func linkable(_ day: String) -> Bool {
            MeetingNote.isLinkable(day: day, kind: .notes, lookbackDays: 7, now: now, calendar: calendar)
        }
        #expect(linkable("2026-11-13"))
        #expect(linkable("2026-11-06"))
        #expect(!linkable("2026-11-05"))
        #expect(!linkable("2026-11-14"))
        #expect(!linkable("../../etc"))
    }

    @Test func pastDatedBriefsAreSkipped() {
        let now = Self.date("2026-11-13T09:00:00-06:00")
        func linkable(_ day: String, _ at: Date = now) -> Bool {
            MeetingNote.isLinkable(day: day, kind: .brief, lookbackDays: 7, now: at, calendar: calendar)
        }
        #expect(linkable("2026-11-13")) // today, even when the meeting is earlier in the day
        #expect(linkable("2026-11-13", Self.date("2026-11-13T23:59:00-06:00")))
        #expect(linkable("2026-11-14"))
        #expect(linkable("2026-11-20"))
        #expect(!linkable("2026-11-21")) // beyond the window
        #expect(!linkable("2026-11-12")) // yesterday: that meeting is over
        #expect(!linkable("2026-11-06"))
        #expect(!linkable("not-a-day"))
    }

    // MARK: Parsing the notes file

    static let notesFile = """
    ---
    type: meeting-notes
    title: "IPE \\"Consult\\""
    date: 2026-11-12
    start: 2026-11-12T08:30:15-06:00
    event_start: 2026-11-12T08:30:00-06:00
    duration_min: 58
    mode: remote
    attendees: ["Ramona Example", "Cynthia Example"]
    transcript: "2026-11-12 0830 IPE Consult"
    ---

    ## Summary
    Short.

    """

    @Test func parsesTheFrontmatterContract() {
        let parsed = MeetingNote.parse(noteId: "Meetings/2026-11-12 0830 IPE Consult.notes.md", source: Self.notesFile)
        #expect(parsed?.link == "Meetings/2026-11-12 0830 IPE Consult.notes")
        #expect(parsed?.title == "IPE \"Consult\"")
        #expect(parsed?.day == "2026-11-12")
        #expect(parsed?.eventStart == Self.date("2026-11-12T08:30:00-06:00"))
        #expect(parsed?.start == Self.date("2026-11-12T08:30:15-06:00"))
        #expect(parsed?.body == "\n## Summary\nShort.\n")
        #expect(parsed?.copiesSummary == true)
    }

    @Test func onlyMeetingNotesParse() {
        let transcript = Self.notesFile.replacingOccurrences(
            of: "type: meeting-notes",
            with: "type: meeting-transcript"
        )
        #expect(MeetingNote.parse(noteId: "a.md", source: transcript) == nil)
        #expect(MeetingNote.parse(noteId: "a.md", source: "# no frontmatter\n") == nil)
        #expect(MeetingNote.parse(noteId: "a.txt", source: Self.notesFile) == nil)
        let quoted = Self.notesFile.replacingOccurrences(of: "type: meeting-notes", with: "type: \"meeting-notes\"")
        #expect(MeetingNote.parse(noteId: "a.md", source: quoted) != nil)
    }

    @Test func aDayThatIsNotADateIsDropped() {
        let bad = Self.notesFile.replacingOccurrences(of: "date: 2026-11-12", with: "date: ../../etc")
        #expect(MeetingNote.parse(noteId: "a.md", source: bad)?.day == nil)
        let untitled = Self.notesFile.replacingOccurrences(of: "title: \"IPE \\\"Consult\\\"\"\n", with: "")
        #expect(MeetingNote.parse(noteId: "a.md", source: untitled)?.title == nil)
    }

    @Test func remoteFalseAndExcludedFolderNotesKeepTheirSummaryLocal() {
        let optedOut = Self.notesFile.replacingOccurrences(
            of: "---\n\n## Summary",
            with: "remote: false\n---\n\n## Summary"
        )
        let parsed = MeetingNote.parse(noteId: "a.md", source: optedOut)
        #expect(parsed?.copiesSummary == false)
        #expect(parsed?.body.contains("Short.") == true) // still counted locally
        let excluded = MeetingNote.parse(
            noteId: "Private/a.md", source: Self.notesFile, policy: ExportPolicy(excludedFolders: ["Private"])
        )
        #expect(excluded?.copiesSummary == false)
    }

    @Test func lockedNotesAreLinkedWithoutReadingTheBody() {
        let locked = "---\ntype: meeting-notes\ndate: 2026-11-12\nlocked: true\nsalt: AAAA\nrounds: 1\n---\nQUJD\n"
        let parsed = MeetingNote.parse(noteId: "a.md", source: locked)
        #expect(parsed?.body == "")
        #expect(parsed?.copiesSummary == false)
        guard let parsed else { return }
        #expect(inserted("# 2026-11-12\n", parsed) == "# 2026-11-12\n\n# Meeting\n[[a]]\n\n")
    }

    @Test func frontmatterStringUnquotes() {
        let frontmatter = Frontmatter(values: [
            "a": "\"x \\\"y\\\" \\\\ z\"", "b": "'it''s'", "c": "plain", "d": "\"",
        ])
        #expect(frontmatter.string("a") == "x \"y\" \\ z")
        #expect(frontmatter.string("b") == "it's")
        #expect(frontmatter.string("c") == "plain")
        #expect(frontmatter.string("d") == "\"")
        #expect(frontmatter.string("missing") == nil)
    }

    @Test func startMinutesParsesCommonTimeShapes() {
        #expect(MeetingNotesInsertion.startMinutes(of: "8:30 AM–9:30 AM") == 510)
        #expect(MeetingNotesInsertion.startMinutes(of: "12:00 PM–1:00 PM") == 720)
        #expect(MeetingNotesInsertion.startMinutes(of: "12:15 AM") == 15)
        #expect(MeetingNotesInsertion.startMinutes(of: "14:30–15:00") == 870)
        #expect(MeetingNotesInsertion.startMinutes(of: "9 a.m.") == 540)
        #expect(MeetingNotesInsertion.startMinutes(of: "All day") == nil)
        #expect(MeetingNotesInsertion.startMinutes(of: "Meeting Notes") == nil)
        #expect(MeetingNotesInsertion.startMinutes(of: "2026-11-12") == nil)
    }
}

import Foundation

/// A `type: meeting-notes` file written into the vault by Audio Transcribe
/// (frontmatter contract: Audio Transcribe spec 00), reduced to what the
/// daily-note planner needs.
public struct MeetingNote: Equatable, Sendable {
    /// Vault-relative path without `.md` — what the inserted `[[…]]` says.
    public let link: String
    /// The meeting's title (frontmatter `title`); nil when no calendar event matched.
    public let title: String?
    /// Frontmatter `date` (`yyyy-MM-dd`): which daily note the meeting belongs to.
    public let day: String?
    public let eventStart: Date?
    public let start: Date?
    /// The notes body (frontmatter stripped). Empty for a locked note.
    public let body: String
    /// False when the note may not leave the Mac (`remote: false`, locked, an
    /// excluded folder): its summary is then NOT copied into the daily note,
    /// which would otherwise carry it into the remote replica. The link and
    /// the action-item count still go in — linking itself is local.
    public let copiesSummary: Bool

    public init(
        link: String,
        title: String?,
        day: String? = nil,
        eventStart: Date?,
        start: Date?,
        body: String,
        copiesSummary: Bool = true
    ) {
        self.link = link
        self.title = title
        self.day = day
        self.eventStart = eventStart
        self.start = start
        self.body = body
        self.copiesSummary = copiesSummary
    }

    /// Reads a vault file as a meeting note. Nil unless its frontmatter says
    /// `type: meeting-notes`. `policy` is the remote-export gate: a note it
    /// would not export keeps its summary out of the daily note. A locked
    /// note's body is ciphertext and is never read as prose.
    public static func parse(
        noteId: String, source: String, policy: ExportPolicy = ExportPolicy()
    ) -> MeetingNote? {
        guard noteId.lowercased().hasSuffix(".md") else { return nil }
        let document = MarkdownDocument(source: source)
        guard let frontmatter = document.frontmatter,
              frontmatter.string("type")?.trimmingCharacters(in: .whitespaces) == "meeting-notes"
        else { return nil }
        let locked = ExportPolicy.looksLocked(source)
        let exportable = policy.decide(relativePath: noteId, contents: source) == .export
        let title = frontmatter.string("title")?.trimmingCharacters(in: .whitespaces)
        let day = frontmatter.string("date")?.trimmingCharacters(in: .whitespaces)
        return MeetingNote(
            link: String(noteId.dropLast(3)),
            title: (title?.isEmpty ?? true) ? nil : title,
            day: day.flatMap { isDay($0) ? $0 : nil },
            eventStart: frontmatter.string("event_start").flatMap(parseTimestamp),
            start: frontmatter.string("start").flatMap(parseTimestamp),
            body: locked ? "" : document.body,
            copiesSummary: exportable && !locked
        )
    }

    /// `yyyy-MM-dd`, digits only — it becomes part of a path (`Daily/<day>.md`).
    public static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }
}

/// Plans where a meeting note's link and summary go in a daily note. Pure: the
/// caller reads and writes the files. The `[[link]]` in the daily note is the
/// only record that linking happened, so planning is idempotent by design.
public enum MeetingNotesInsertion {
    public enum Plan: Equatable, Sendable {
        /// The daily note already links to the meeting note: write nothing.
        case alreadyLinked
        /// The daily note's full new text.
        case insert(String)
        /// The note's path cannot be written as a `[[link]]` that resolves back to it (it
        /// holds `#`, `|`, `[` or `]`). Write nothing: an unresolvable link would never count
        /// as "already linked", so every later pass would insert the block again.
        case unlinkable
    }

    /// The top-level heading the daily-note template puts the week's to-dos under.
    static let toDoHeading = "To-Do This Week"
    /// Separator between time and title in `CalendarService.meetingsMarkdown` headings.
    static let titleSeparator = " — "

    public static func plan(
        dailyNote text: String, note: MeetingNote, calendar: Calendar = .current
    ) -> Plan {
        guard let written = WikilinkSyntax.links(in: "[[\(note.link)]]").first,
              written.target == note.link, written.heading == nil, written.blockId == nil, written.alias == nil
        else { return .unlinkable }
        if isLinked(text, to: note) {
            return .alreadyLinked
        }
        var lines = splitLines(text)
        let cr = text.contains("\r\n") ? "\r" : ""
        let block = blockLines(for: note).map { $0 + cr }
        let headings = topLevelHeadings(lines)
        let meetings = headings.compactMap(MeetingHeading.init)

        if let title = note.title, let heading = bestMatch(
            meetings.filter { $0.title.compare(title, options: .caseInsensitive) == .orderedSame },
            eventStart: note.eventStart, calendar: calendar
        ) {
            let at = heading.line + 1
            // The empty piece after a final newline is the end of the file,
            // not a blank line.
            let isEnd = at >= lines.count || (at == lines.count - 1 && lines[at].isEmpty)
            let blankFollows = !isEnd && lines[at].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lines.insert(contentsOf: block + (blankFollows ? [] : [cr]), at: at)
            return .insert(lines.joined(separator: "\n"))
        }

        // No matching heading: make one, after the last meeting section, else
        // before the to-do section, else at the end.
        var at: Int = if let last = meetings.last {
            headings.first { $0.line > last.line }?.line ?? lines.count
        } else if let toDo = headings.first(where: {
            $0.text.compare(toDoHeading, options: .caseInsensitive) == .orderedSame
        }) {
            toDo.line
        } else {
            lines.count
        }
        if at == lines.count, lines.last?.isEmpty == true {
            at -= 1 // before the empty piece after a final newline
        }
        var chunk: [String] = []
        if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunk.append(cr)
        }
        chunk.append(newHeading(for: note, calendar: calendar) + cr)
        chunk += block
        chunk.append(cr)
        lines.insert(contentsOf: chunk, at: at)
        return .insert(lines.joined(separator: "\n"))
    }

    // MARK: Block

    /// `[[link]]`, the `## Summary` body, the open-action-item line.
    static func blockLines(for note: MeetingNote) -> [String] {
        var lines = ["[[\(note.link)]]"]
        if note.copiesSummary {
            lines += summaryLines(of: note.body)
        }
        let open = openActionItemCount(in: note.body)
        if open > 0 {
            lines.append("Action items: \(open) open — see linked notes")
        }
        return lines
    }

    /// The body of the `## Summary` section (up to the next `#`/`##` heading),
    /// blank edges trimmed and task lines dropped — every task stays in the
    /// notes file only, so it is indexed once.
    static func summaryLines(of body: String) -> [String] {
        let lines = splitLines(body).map(strippingCarriageReturn)
        var start: Int?
        var end = lines.count
        for heading in headingLines(lines) {
            if let found = start {
                if heading.line > found, heading.level <= 2 {
                    end = heading.line
                    break
                }
            } else if heading.level == 2,
                      heading.text.compare("Summary", options: .caseInsensitive) == .orderedSame {
                start = heading.line
            }
        }
        guard let start else { return [] }
        var section = Array(lines[(start + 1) ..< end])
        let taskLines = Set(NoteScanner.tasks(in: section.joined(separator: "\n")).map(\.line))
        section = section.enumerated().filter { !taskLines.contains($0.offset) }.map(\.element)
        while section.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            section.removeFirst()
        }
        while section.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            section.removeLast()
        }
        return section
    }

    /// Unchecked `- [ ]` lines anywhere in the notes body.
    static func openActionItemCount(in body: String) -> Int {
        NoteScanner.tasks(in: body).count { !$0.checked }
    }

    // MARK: Linking

    /// True when any `[[…]]` in the daily note resolves to the meeting note —
    /// resolution is `WikilinkSyntax.resolve`, the one every click site uses.
    static func isLinked(_ text: String, to note: MeetingNote) -> Bool {
        let id = note.link + ".md"
        let title = (note.link as NSString).lastPathComponent
        let candidates = [(id: id, title: title)]
        return WikilinkSyntax.links(in: text).contains {
            WikilinkSyntax.resolve($0, among: candidates, from: nil) == id
        }
    }

    // MARK: Headings

    struct Heading {
        let line: Int
        let level: Int
        let text: String
    }

    /// `# <time> — <title>` as `CalendarService.meetingsMarkdown` writes it
    /// (`# 8:30 AM–9:30 AM — IPE Consult`, `# All day — Retreat`).
    struct MeetingHeading {
        let line: Int
        let title: String
        /// Minutes after midnight of the start time; nil for "All day".
        let startMinutes: Int?

        init?(_ heading: Heading) {
            guard let separator = heading.text.range(of: MeetingNotesInsertion.titleSeparator) else { return nil }
            let time = heading.text[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let minutes = MeetingNotesInsertion.startMinutes(of: time)
            guard minutes != nil || time.compare("All day", options: .caseInsensitive) == .orderedSame
            else { return nil }
            line = heading.line
            title = heading.text[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            startMinutes = minutes
        }
    }

    static func topLevelHeadings(_ lines: [String]) -> [Heading] {
        headingLines(lines.map(strippingCarriageReturn)).filter { $0.level == 1 }
    }

    /// ATX headings outside frontmatter and fenced code.
    static func headingLines(_ lines: [String]) -> [Heading] {
        var result: [Heading] = []
        var fence: String?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0, trimmed == "---" {
                fence = "---"
                continue
            }
            if let open = fence {
                if open == "---" ? (trimmed == "---" || trimmed == "...") : trimmed.hasPrefix(open) {
                    fence = nil
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            let level = trimmed.prefix { $0 == "#" }.count
            guard (1 ... 6).contains(level) else { continue }
            let rest = trimmed.dropFirst(level)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { continue }
            result.append(Heading(line: index, level: level, text: rest.trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// Several headings share the title: the one starting closest to the
    /// event, else the first.
    static func bestMatch(_ matches: [MeetingHeading], eventStart: Date?, calendar: Calendar) -> MeetingHeading? {
        guard matches.count > 1, let eventStart else { return matches.first }
        let parts = calendar.dateComponents([.hour, .minute], from: eventStart)
        let target = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        var best = matches[0]
        var bestDistance = Int.max
        for match in matches {
            guard let minutes = match.startMinutes else { continue }
            let distance = abs(minutes - target)
            if distance < bestDistance {
                best = match
                bestDistance = distance
            }
        }
        return best
    }

    /// The start of a heading's time range — `8:30 AM–9:30 AM`, `8:30 AM`,
    /// `14:30` — in minutes after midnight. Tolerates the narrow no-break
    /// space recent macOS puts before AM/PM.
    static func startMinutes(of time: String) -> Int? {
        let normalized = time
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let first = normalized.split(whereSeparator: { $0 == "–" || $0 == "-" }).first.map(String.init) ?? ""
        var rest = Substring(first.trimmingCharacters(in: .whitespaces).lowercased())
        let hourDigits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1 ... 2).contains(hourDigits.count), var hour = Int(hourDigits) else { return nil }
        rest = rest.dropFirst(hourDigits.count)
        var minute = 0
        if rest.first == ":" || rest.first == "." {
            let minuteDigits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
            guard minuteDigits.count == 2, let value = Int(minuteDigits) else { return nil }
            minute = value
            rest = rest.dropFirst(1 + minuteDigits.count)
        }
        let suffix = rest.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
        switch suffix {
        case "":
            guard hour < 24 else { return nil }
        case "am", "a":
            guard (1 ... 12).contains(hour) else { return nil }
            hour = hour == 12 ? 0 : hour
        case "pm", "p":
            guard (1 ... 12).contains(hour) else { return nil }
            hour = hour == 12 ? 12 : hour + 12
        default:
            return nil
        }
        guard minute < 60 else { return nil }
        return hour * 60 + minute
    }

    /// `# 8:30 AM — Title` for a meeting the calendar never put in the note.
    static func newHeading(for note: MeetingNote, calendar: Calendar) -> String {
        let title = note.title ?? "Meeting"
        guard let when = note.eventStart ?? note.start else { return "# \(title)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        return "# \(formatter.string(from: when))\(titleSeparator)\(title)"
    }
}

import CalendarKit
import EventKit
import SwiftUI

/// Day/Week agenda over the calendars included in Settings › Calendar.
/// Single pane with an in-content header (no split view, no toolbar) — the
/// beta toolbar bridge breaks `.toolbar`/`.navigationTitle` on macOS.
struct CalendarView: View {
    let openDailyNote: (Date) -> Void

    @AppStorage("calendarTabRange") private var rangeMode = "week"
    @Environment(\.scenePhase) private var scenePhase
    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @State private var days: [AgendaDay] = []
    @State private var access = CalendarService.accessState()
    @State private var hasCalendars = true
    @State private var expanded: Set<String> = []

    private var calendar: Calendar {
        .current
    }

    private var isWeek: Bool {
        rangeMode != "day"
    }

    private var range: AgendaRange {
        isWeek ? .week(from: anchor) : .day(anchor)
    }

    var body: some View {
        #if os(iOS)
            NavigationStack {
                inner.navigationTitle("Calendar")
            }
        #else
            inner
        #endif
    }

    private var inner: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: reloadKey) { reload() }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                reload()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                reload()
            }
        }
    }

    private var reloadKey: String {
        "\(anchor.timeIntervalSince1970)-\(rangeMode)"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .help(isWeek ? "Previous week" : "Previous day")
            Button("Today") { anchor = calendar.startOfDay(for: Date()) }
                .help("Jump to today")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .help(isWeek ? "Next week" : "Next day")
            Picker("Range", selection: $rangeMode) {
                Text("Day").tag("day")
                Text("Week").tag("week")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            Text(titleText)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button("Daily Note", systemImage: "note.text") {
                openDailyNote(anchor)
            }
            .help("Open the daily note for \(DayKey.string(for: anchor, calendar: calendar))")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.headerBackground)
    }

    private var titleText: String {
        if !isWeek {
            return anchor.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        let last = calendar.date(byAdding: .day, value: 6, to: anchor) ?? anchor
        let first = anchor.formatted(.dateTime.month(.abbreviated).day())
        let end = last.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(first) – \(end)"
    }

    private func step(_ direction: Int) {
        let n = isWeek ? 7 : 1
        anchor = calendar.date(byAdding: .day, value: direction * n, to: anchor) ?? anchor
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch access {
        case .notRequested:
            ContentUnavailableView {
                Label("Connect Your Calendars", systemImage: "calendar.badge.plus")
            } description: {
                Text("Show events from every calendar in the system Calendar app. Nothing leaves this device.")
            } actions: {
                Button("Connect Calendars…") {
                    Task {
                        _ = await CalendarService.requestAccess()
                        reload()
                    }
                }
            }
        case .denied:
            ContentUnavailableView(
                "Calendar Access Denied", systemImage: "calendar.badge.exclamationmark",
                description: Text("Allow Notetaker in System Settings › Privacy & Security › Calendars.")
            )
        case .granted:
            if !hasCalendars {
                ContentUnavailableView(
                    "No Calendars Included", systemImage: "calendar",
                    description: Text("No calendars included — pick them in Settings › Calendar.")
                )
            } else {
                agenda
            }
        }
    }

    private var agenda: some View {
        let now = Date()
        return List {
            ForEach(days) { day in
                Section(sectionTitle(day.date)) {
                    if day.events.isEmpty, isWeek {
                        Text("No events").foregroundStyle(.secondary)
                    } else if day.events.isEmpty {
                        Text("No events today").foregroundStyle(.secondary)
                    }
                    ForEach(day.events) { event in
                        row(event, day: day.date, now: now)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func sectionTitle(_ date: Date) -> String {
        let short = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if calendar.isDateInToday(date) {
            return "Today · \(short)"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow · \(short)"
        }
        return short
    }

    private func timeText(_ e: CalendarEvent) -> String {
        if e.allDay {
            return "All day"
        }
        let t = Date.FormatStyle(time: .shortened)
        return "\(e.start.formatted(t)) – \(e.end.formatted(t))"
    }

    private func row(_ e: CalendarEvent, day: Date, now: Date) -> some View {
        let current = !e.allDay && e.start <= now && now < e.end
        let key = "\(e.id)|\(day.timeIntervalSince1970)"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: e.calendarColorHex) ?? .accentColor)
                    .frame(width: 3, height: 28)
                Text(timeText(e))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title)
                        .font(.body)
                        .strikethrough(e.status == .canceled)
                        .foregroundStyle(e.status == .canceled ? .secondary : .primary)
                    Text(e.location ?? e.calendarTitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if expanded.contains(key) {
                VStack(alignment: .leading, spacing: 2) {
                    if let o = e.organizer {
                        Text("Organizer: \(o)")
                    }
                    if !e.attendees.isEmpty {
                        Text("Attendees: \(e.attendees.joined(separator: ", "))")
                    }
                    Text("Calendar: \(e.calendarTitle)\(accountSuffix(e))")
                    Text("Status: \(e.status.rawValue)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 119)
            }
        }
        .fontWeight(current ? .semibold : .regular)
        .contentShape(Rectangle())
        .onTapGesture {
            if !expanded.insert(key).inserted {
                expanded.remove(key)
            }
        }
        .listRowBackground(current ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func accountSuffix(_ e: CalendarEvent) -> String {
        guard let acct = accounts[e.calendarId], !acct.isEmpty else { return "" }
        return " (\(acct))"
    }

    @State private var accounts: [String: String] = [:]

    // MARK: Loading

    private func reload() {
        access = CalendarService.accessState()
        guard access == .granted else {
            days = []
            return
        }
        let included = CalendarService.includedCalendars()
        hasCalendars = !included.isEmpty
        accounts = Dictionary(included.map { ($0.id, $0.account) }, uniquingKeysWith: { a, _ in a })
        let bounds = range.bounds(calendar: calendar)
        let events = CalendarService.events(from: bounds.start, to: bounds.end)
        days = AgendaBuilder.days(events: events, range: range, calendar: calendar)
    }
}

private extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let v = UInt32(hex.dropFirst(), radix: 16)
        else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

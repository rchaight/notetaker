import EditorKit
import SwiftUI

/// Every user-invokable command, once. The menu bar (`NotetakerCommands`),
/// the command palette and the editor header's ⋯ menu all build from
/// `ShellCommand.allCases`, so a title, shortcut or availability rule is
/// changed in exactly one place. Data only — no behaviour lives here; the
/// surfaces that own the state (`AppShell`, `NotesView`) perform the work
/// when they see a command arrive on the `ShellCommandBus`.
enum ShellCommand: String, CaseIterable, Identifiable {
    /// File
    case newNote, newTask, newProject, dailyNote, renameNote, closeNote, closeWindow, refreshVault
    /// Edit
    case findInNote
    /// Format
    case bold, italic, strikethrough, code, headingTitle, headingH2, headingH3, bodyText,
         bulletList, numberedList, todoList, quote, link, insertTable, insertImage, insertRule
    /// View
    case nextMode, toggleSourceLive, modeSource, modeLive, modeReading,
         zoomIn, zoomOut, actualSize, focusMode, inspector
    /// Note
    case proofread, lockNote, toggleProject, summarize, extractActions, linkGraph, moveToTrash
    /// Go
    case goNotes, goTodo, goProjects, goMeetings, goCalendar, goTags, goVault, commandPalette

    var id: String {
        rawValue
    }

    /// Menu / palette label.
    var title: String {
        switch self {
        case .newNote: "New Note"
        case .newTask: "New Task…"
        case .newProject: "New Project"
        case .dailyNote: "Today's Daily Note"
        case .renameNote: "Rename Note…"
        case .closeNote: "Close Note"
        case .closeWindow: "Close Window"
        case .refreshVault: "Refresh from iCloud"
        case .findInNote: "Find in Note"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .code: "Code"
        case .headingTitle: "Title"
        case .headingH2: "Heading"
        case .headingH3: "Subheading"
        case .bodyText: "Body"
        case .bulletList: "Bullet List"
        case .numberedList: "Numbered List"
        case .todoList: "To-Do"
        case .quote: "Quote"
        case .link: "Link…"
        case .insertTable: "Table"
        case .insertImage: "Image…"
        case .insertRule: "Horizontal Rule"
        case .nextMode: "Next Mode"
        case .toggleSourceLive: "Toggle Source"
        case .modeSource: "Source"
        case .modeLive: "Live Preview"
        case .modeReading: "Reading"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .focusMode: "Focus Mode"
        case .inspector: "Show Inspector"
        case .proofread: "Proofread…"
        case .lockNote: "Lock Note"
        case .toggleProject: "Make Project"
        case .summarize: "Summarize Note"
        case .extractActions: "Extract Action Items"
        case .linkGraph: "Link Graph…"
        case .moveToTrash: "Move to Trash…"
        case .goNotes: "Notes"
        case .goTodo: "To-Do"
        case .goProjects: "Projects"
        case .goMeetings: "Meetings"
        case .goCalendar: "Calendar"
        case .goTags: "Tags"
        case .goVault: "Vault"
        case .commandPalette: "Command Palette…"
        }
    }

    var systemImage: String {
        switch self {
        case .newNote: "square.and.pencil"
        case .newTask: "plus.circle"
        case .newProject: "calendar.day.timeline.left"
        case .dailyNote: "calendar"
        case .renameNote: "pencil"
        case .closeNote: "xmark"
        case .closeWindow: "xmark.rectangle"
        case .refreshVault: "arrow.clockwise"
        case .findInNote: "magnifyingglass"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .headingTitle, .headingH2, .headingH3: "textformat.size"
        case .bodyText: "textformat"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .todoList: "checklist"
        case .quote: "quote.opening"
        case .link: "link"
        case .insertTable: "tablecells"
        case .insertImage: "photo"
        case .insertRule: "minus"
        case .nextMode: "arrow.triangle.2.circlepath"
        case .toggleSourceLive: "arrow.left.arrow.right"
        case .modeSource: "chevron.left.forwardslash.chevron.right"
        case .modeLive: "eye"
        case .modeReading: "book"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .actualSize: "1.magnifyingglass"
        case .focusMode: "circle.circle"
        case .inspector: "sidebar.right"
        case .proofread: "text.badge.checkmark"
        case .lockNote: "lock"
        case .toggleProject: "calendar.day.timeline.left"
        case .summarize: "text.append"
        case .extractActions: "checklist"
        case .linkGraph: "point.3.connected.trianglepath.dotted"
        case .moveToTrash: "trash"
        case .goNotes: "note.text"
        case .goTodo: "checklist"
        case .goProjects: "calendar.day.timeline.left"
        case .goMeetings: "person.3"
        case .goCalendar: "calendar"
        case .goTags: "number"
        case .goVault: "icloud"
        case .commandPalette: "command"
        }
    }

    /// The menu-bar key equivalent. ⌃⌥⌘N (system-wide capture) is a Carbon
    /// hotkey, not a SwiftUI shortcut, and is not in this table.
    var shortcut: KeyboardShortcut? {
        func key(_ character: KeyEquivalent, _ modifiers: EventModifiers = .command) -> KeyboardShortcut {
            KeyboardShortcut(character, modifiers: modifiers)
        }
        switch self {
        case .newNote: return key("n")
        case .newTask: return key("n", [.command, .shift])
        case .dailyNote: return key("d", [.command, .shift])
        case .renameNote: return key("r", [.command, .option])
        case .closeNote: return key("w")
        case .closeWindow: return key("w", [.command, .shift])
        case .refreshVault: return key("r")
        case .findInNote: return key("f")
        case .bold: return key("b")
        case .italic: return key("i", [.command, .shift])
        case .code: return key("c", [.command, .option])
        case .todoList: return key("t", [.command, .shift])
        case .link: return key("k", [.command, .shift])
        case .nextMode: return key("e")
        case .toggleSourceLive: return key("/")
        case .zoomIn: return key("=")
        case .zoomOut: return key("-")
        case .actualSize: return key("0")
        case .inspector: return key("0", [.command, .option])
        case .proofread: return key("p", [.command, .shift])
        case .goNotes: return key("1")
        case .goTodo: return key("2")
        case .goProjects: return key("3")
        case .goMeetings: return key("4")
        case .goCalendar: return key("5")
        case .goTags: return key("6")
        case .goVault:
            #if DEBUG
                return key("7")
            #else
                return nil
            #endif
        case .commandPalette: return key("k")
        default: return nil
        }
    }

    /// "⌘N" — for palette rows.
    var shortcutLabel: String? {
        guard let shortcut else { return nil }
        var label = ""
        if shortcut.modifiers.contains(.control) {
            label += "⌃"
        }
        if shortcut.modifiers.contains(.option) {
            label += "⌥"
        }
        if shortcut.modifiers.contains(.shift) {
            label += "⇧"
        }
        if shortcut.modifiers.contains(.command) {
            label += "⌘"
        }
        return label + String(shortcut.key.character).uppercased()
    }

    /// Who can perform the command, and therefore when it is enabled.
    enum Scope {
        /// `AppShell` performs it; works from every tab.
        case shell
        /// Needs the Notes tab mounted (`NotesView` performs it).
        case notesTab
        /// Needs the Notes tab mounted with an unlocked note open.
        case openNote
        /// Needs an unlocked note open in Source or Live (not Reading).
        case editing
    }

    var scope: Scope {
        switch self {
        case .newNote, .newTask, .newProject, .dailyNote, .closeNote, .closeWindow, .refreshVault,
             .goNotes, .goTodo, .goProjects, .goMeetings, .goCalendar, .goTags, .goVault, .commandPalette:
            .shell
        case .renameNote, .findInNote, .nextMode, .toggleSourceLive, .modeSource, .modeLive, .modeReading,
             .zoomIn, .zoomOut, .actualSize, .focusMode, .inspector,
             .lockNote, .toggleProject, .summarize, .extractActions, .linkGraph, .moveToTrash:
            .openNote
        case .bold, .italic, .strikethrough, .code, .headingTitle, .headingH2, .headingH3, .bodyText,
             .bulletList, .numberedList, .todoList, .quote, .link, .insertTable, .insertImage, .insertRule,
             .proofread:
            .editing
        }
    }

    /// The editor operation behind a Format-menu command; `nil` for commands
    /// that do something else (link opens an edit sheet, insertImage a file
    /// picker). The format-bar buttons and the menu both read this, so the
    /// two cannot disagree about what "Bold" writes.
    var editorCommand: EditorCommand? {
        switch self {
        case .bold: .wrap(prefix: "**", suffix: "**")
        case .italic: .wrap(prefix: "*", suffix: "*")
        case .strikethrough: .wrap(prefix: "~~", suffix: "~~")
        case .code: .wrap(prefix: "`", suffix: "`")
        case .headingTitle: .setHeading(1)
        case .headingH2: .setHeading(2)
        case .headingH3: .setHeading(3)
        case .bodyText: .setHeading(0)
        case .bulletList: .toggleLinePrefix("- ")
        case .numberedList: .toggleLinePrefix("1. ")
        case .todoList: .toggleLinePrefix("- [ ] ")
        case .quote: .toggleLinePrefix("> ")
        case .insertTable: .insertBlock("| Column 1 | Column 2 |\n| --- | --- |\n|  |  |", cursorOffset: 2)
        case .insertRule: .insertBlock("---", cursorOffset: nil)
        default: nil
        }
    }

    @MainActor func isAvailable(_ bus: ShellCommandBus) -> Bool {
        switch scope {
        case .shell: return true
        case .notesTab: return bus.notesTabVisible
        case .openNote: return bus.notesTabVisible && bus.hasOpenNote
        case .editing:
            guard bus.notesTabVisible, bus.isEditing else { return false }
            return self == .proofread ? bus.languageToolConfigured : true
        }
    }
}

/// The meeting point between the menu bar and the views that own state.
/// Surfaces PUBLISH what is true right now (so menu items can enable and
/// disable) and CONSUME one-shot requests (`requestID` bumps per command).
/// Owned by `NotetakerApp`, not `AppShell`: the shell is rebuilt on a vault
/// switch (`.id(activeVault)`) and the menu must outlive it.
@MainActor @Observable
final class ShellCommandBus {
    /// Published by `NotesView`: only true while the Notes tab is mounted.
    var notesTabVisible = false
    /// A note is open and is not the locked placeholder.
    var hasOpenNote = false
    /// `hasOpenNote` and the editor mode is Source or Live.
    var isEditing = false
    var editorMode: EditorMode = .live
    var languageToolConfigured = false
    /// Flip the Lock / Project menu titles.
    var selectedIsLockable = false
    var selectedIsProject = false
    /// Drives the Show Inspector checkmark.
    var inspectorVisible = false

    /// One-shot request; consumers key `.onChange` on `requestID` and then
    /// read `pending`.
    private(set) var requestID = 0
    private(set) var pending: ShellCommand?

    func perform(_ command: ShellCommand) {
        pending = command
        requestID += 1
    }

    /// Writes only a changed value: an `@Observable` write notifies even
    /// when the value is equal, and each notification rebuilds the menu.
    func publish<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ShellCommandBus, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

#if os(macOS)
    /// The menu bar. Every item is a `ShellCommand` routed through the bus;
    /// nothing here touches a model or a view.
    struct NotetakerCommands: Commands {
        let bus: ShellCommandBus
        /// Same key `NotesView` writes; drives the Focus Mode checkmark.
        @AppStorage("editorFocusMode") private var focusMode = false

        var body: some Commands {
            // The system "New" group (New Window) is replaced: ⌘N is ours.
            // `.saveItem` (where a document app keeps Close) does not exist
            // for a WindowGroup-only app, so Close Note / Close Window /
            // Refresh go after the New items; with ⌘W claimed here the
            // system "Close" item loses its key equivalent on its own.
            CommandGroup(replacing: .newItem) {
                item(.newNote)
                item(.newTask)
                item(.newProject)
                item(.dailyNote)
                item(.renameNote)
            }
            CommandGroup(after: .newItem) {
                Divider()
                item(.closeNote)
                item(.closeWindow)
                Divider()
                item(.refreshVault)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                item(.findInNote)
            }
            CommandMenu("Format") {
                Menu("Heading") {
                    item(.headingTitle)
                    item(.headingH2)
                    item(.headingH3)
                    Divider()
                    item(.bodyText)
                }
                Divider()
                item(.bold)
                item(.italic)
                item(.strikethrough)
                item(.code)
                Divider()
                item(.bulletList)
                item(.numberedList)
                item(.todoList)
                item(.quote)
                Divider()
                item(.link)
                Menu("Insert") {
                    item(.insertTable)
                    item(.insertImage)
                    item(.insertRule)
                }
            }
            // SwiftUI already owns a View menu; join it rather than add a second.
            CommandGroup(after: .sidebar) {
                checked(.modeSource, bus.editorMode == .source)
                checked(.modeLive, bus.editorMode == .live)
                checked(.modeReading, bus.editorMode == .reading)
                item(.nextMode)
                item(.toggleSourceLive)
                Divider()
                item(.zoomIn)
                item(.zoomOut)
                item(.actualSize)
                Divider()
                checked(.focusMode, focusMode)
                checked(.inspector, bus.inspectorVisible)
            }
            CommandMenu("Note") {
                item(.proofread)
                item(.summarize)
                item(.extractActions)
                Divider()
                item(.lockNote, title: bus.selectedIsLockable ? "Remove Lock" : "Lock Note")
                item(.toggleProject, title: bus.selectedIsProject ? "Remove Project Flag" : "Make Project")
                Divider()
                item(.linkGraph)
                Divider()
                item(.moveToTrash)
            }
            CommandMenu("Go") {
                item(.goNotes)
                item(.goTodo)
                item(.goProjects)
                item(.goMeetings)
                item(.goCalendar)
                item(.goTags)
                #if DEBUG
                    item(.goVault)
                #endif
                Divider()
                item(.commandPalette)
            }
        }

        private func item(_ command: ShellCommand, title: String? = nil) -> some View {
            Button(title ?? command.title) { bus.perform(command) }
                .keyboardShortcut(command.shortcut)
                .disabled(!command.isAvailable(bus))
        }

        /// A checkmarked item: the state is read from the bus (or defaults),
        /// the click only sends the command.
        private func checked(_ command: ShellCommand, _ isOn: Bool) -> some View {
            Toggle(command.title, isOn: Binding(get: { isOn }, set: { _ in bus.perform(command) }))
                .keyboardShortcut(command.shortcut)
                .disabled(!command.isAvailable(bus))
        }
    }
#endif

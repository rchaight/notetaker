import AppIntents
import Foundation

/// ONE intent family feeding Siri, Shortcuts, and Spotlight actions.
/// (Lives in the app target: App Intents metadata extraction requires it;
/// AppIntentsKit stays reserved for shared pure helpers.)
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription(
        "Adds a task to your Notetaker inbox. Natural dates and tokens work: \"email dean tomorrow p1 #admin\"."
    )

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to the inbox")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await HeadlessVaultWriter.addTask(text) else {
            return .result(dialog: "Couldn't reach your vault.")
        }
        return .result(dialog: "Added to your inbox.")
    }
}

struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription("Creates a markdown note in your Notetaker vault.")

    @Parameter(title: "Title", requestValueDialog: "What should the note be called?")
    var noteTitle: String

    @Parameter(title: "Content", default: "")
    var content: String

    static var parameterSummary: some ParameterSummary {
        Summary("Create note \(\.$noteTitle) with \(\.$content)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let name = await HeadlessVaultWriter.createNote(
            titled: noteTitle, body: content
        ) else {
            return .result(dialog: "Couldn't reach your vault.")
        }
        return .result(dialog: "Created \(name).")
    }
}

/// Registers the phrases Siri and Spotlight surface.
struct NotetakerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: ["Add a task in \(.applicationName)"],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: ["Create a note in \(.applicationName)"],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
    }
}

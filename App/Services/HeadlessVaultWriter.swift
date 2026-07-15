import Foundation
import TaskEngine
import VaultKit

/// Vault writes that work WITHOUT the running UI: menu-bar capture, App
/// Intents (Siri/Shortcuts), widgets. Resolves the root the same way the
/// app does; coordinated writes mean the app's observers pick changes up.
enum HeadlessVaultWriter {
    static let store = VaultFileStore()

    static func vaultRoot() -> URL? {
        VaultRegistry.activeCustomRoot()
            ?? UbiquityContainer.wellKnownDocumentsURL(
                containerIdentifier: "iCloud.com.rchaight.notetaker"
            )
    }

    /// Parses through the ONE task grammar and appends to Inbox.md.
    @discardableResult
    static func addTask(_ input: String) async -> Bool {
        guard let root = vaultRoot(),
              let line = QuickAddParser.parse(input)?.markdownLine else { return false }
        let inbox = root.appendingPathComponent("Inbox.md")
        let existing = await (try? store.readString(at: inbox)) ?? "# Inbox\n"
        let updated = (existing.hasSuffix("\n") ? existing : existing + "\n") + line + "\n"
        return await (try? store.writeString(updated, to: inbox)) != nil
    }

    /// Creates a note (uniquified) and returns its file name.
    @discardableResult
    static func createNote(titled title: String, body: String = "") async -> String? {
        guard let root = vaultRoot() else { return nil }
        let clean = NotesModel.sanitizeFileName(
            title.isEmpty ? "Untitled" : title
        )
        let name = VaultNaming.uniqueFileName(base: clean, ext: "md", in: root)
        let contents = "# \(clean)\n\n" + (body.isEmpty ? "" : body + "\n")
        guard await (try? store.writeString(
            contents, to: root.appendingPathComponent(name)
        )) != nil else { return nil }
        return name
    }
}

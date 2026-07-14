import Foundation
import MarkdownKit
import Observation
import VaultKit

/// Drives the Notes tab: live vault listing, note selection, load, and
/// debounced coordinated autosave. Files remain the source of truth — this
/// model never holds state that can't be rebuilt from the vault.
@MainActor
@Observable
final class NotesModel {
    enum VaultState: Equatable {
        case loading
        case ready
        /// Vault works, but against local storage — iCloud was unreachable.
        case readyLocalFallback
        case unavailable(String)
    }

    var state: VaultState = .loading
    var notes: [VaultItem] = []
    /// Folder relative paths present on disk (the vault tree IS the scheme).
    var folders: [String] = []
    /// Open note tabs, in open order (selection switches, ✕ closes).
    var openTabs: [VaultItem.ID] = []
    var selectedID: VaultItem.ID?
    var noteText = ""

    private(set) var root: URL?
    /// Recently opened notes, newest first (device-local UI state).
    private(set) var recents: [String] =
        UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []
    private let store = VaultFileStore()
    private var observer: MetadataQueryObserver?
    private var observation: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadedURL: URL?
    private var dirty = false

    private var started = false
    #if os(macOS)
        private var watcher: DirectoryWatcher?
    #endif

    func start() async {
        guard !started else { return }
        started = true

        #if os(macOS)
            if let custom = VaultRegistry.activeCustomRoot() {
                root = custom
                apply(VaultEnumerator.snapshot(of: custom))
                state = .ready
                let watcher = DirectoryWatcher(root: custom)
                self.watcher = watcher
                observation = Task {
                    for await _ in watcher.events {
                        if let root = self.root {
                            self.apply(VaultEnumerator.snapshot(of: root))
                        }
                    }
                }
                return
            }
        #endif

        // Show the list IMMEDIATELY — cold ubiquity resolution can take
        // seconds and must never blank the UI. Cached root first, then the
        // container's deterministic on-disk path.
        let provisional = UserDefaults.standard.string(forKey: "lastVaultRoot")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? UbiquityContainer.wellKnownDocumentsURL(containerIdentifier: "iCloud.com.rchaight.notetaker")
        if let provisional {
            root = provisional
            apply(VaultEnumerator.snapshot(of: provisional))
            state = .ready
        }

        do {
            let documents = try await UbiquityContainer.documentsURL()
            root = documents
            UserDefaults.standard.set(documents.path, forKey: "lastVaultRoot")
            apply(VaultEnumerator.snapshot(of: documents))
            state = .ready

            let observer = MetadataQueryObserver(root: documents)
            self.observer = observer
            observation = Task {
                for await snapshot in observer.snapshots() {
                    self.apply(snapshot)
                }
            }
        } catch {
            // Cached root already serving? Keep it — don't downgrade the UI.
            if state == .ready, root != nil {
                return
            }
            // No iCloud (signed out, disabled, or simulator): fall back to a
            // local vault so the app still works; notes migrate to iCloud
            // when it becomes available (vault root is re-resolved on launch).
            do {
                let local = try FileManager.default
                    .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("LocalVault", isDirectory: true)
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                root = local
                apply(VaultEnumerator.snapshot(of: local))
                state = .readyLocalFallback
            } catch {
                state = .unavailable("No vault available: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        observer?.stop()
        observation?.cancel()
        #if os(macOS)
            watcher?.stop()
        #endif
    }

    /// Markdown files only, stable order; folder set captured alongside.
    private func apply(_ snapshot: [VaultItem]) {
        notes = snapshot
            .filter { !$0.isDirectory && $0.relativePath.lowercased().hasSuffix(".md") }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        var seen = Set(snapshot.filter(\.isDirectory).map(\.relativePath))
        // Folders implied by note paths count even if the dir entry is absent
        // from a partial snapshot.
        for note in notes {
            let components = note.relativePath.split(separator: "/").dropLast()
            var path = ""
            for component in components {
                path = path.isEmpty ? String(component) : path + "/" + component
                seen.insert(path)
            }
        }
        folders = seen.filter { !$0.isEmpty }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        openTabs.removeAll { id in !notes.contains { $0.id == id } }
    }

    /// Cross-tab jump: open a note and remember the source line so the
    /// editor can scroll to it once the text is loaded.
    private(set) var pendingJumpLine: Int?

    func openNote(_ id: String, jumpToLine line: Int?) {
        pendingJumpLine = line
        select(id)
    }

    func consumeJumpLine() -> Int? {
        defer { pendingJumpLine = nil }
        return pendingJumpLine
    }

    func select(_ id: VaultItem.ID?) {
        Task { await performSelect(id) }
    }

    private func performSelect(_ id: VaultItem.ID?) async {
        await flushSave()
        selectedID = id
        if let id, !recents.contains(id) {
            // Insert-only: reordering existing entries makes the Recents
            // section shuffle under the cursor mid-click (user report).
            recents.insert(id, at: 0)
            if recents.count > 8 { recents.removeLast(recents.count - 8) }
            UserDefaults.standard.set(recents, forKey: "recentNotes")
        }
        if let id, !openTabs.contains(id) {
            openTabs.append(id)
        }
        guard let id, let item = notes.first(where: { $0.id == id }) else {
            loadedURL = nil
            noteText = ""
            return
        }
        do {
            try? store.startDownloading(item.url)
            let contents = try await store.readString(at: item.url)
            loadedURL = item.url
            noteText = contents
            dirty = false
        } catch {
            loadedURL = nil
            noteText = ""
        }
    }

    /// An external mutation (to-do toggle, quick add) rewrote a note file.
    /// If it's the note on screen and the editor has no unsaved typing,
    /// re-read so the visible markdown matches the file.
    func reloadIfDisplayed(noteId: String) {
        guard selectedID == noteId, !dirty, let url = loadedURL else { return }
        Task {
            guard let contents = try? await store.readString(at: url),
                  !dirty, loadedURL == url, contents != noteText else { return }
            noteText = contents
        }
    }

    /// Called on every editor keystroke; schedules a debounced autosave.
    func textChanged() {
        guard loadedURL != nil else { return }
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await flushSave()
        }
    }

    /// allowRename: false when a service mutation is about to rewrite the
    /// file — a title-sync rename here would move it out from under the
    /// mutation's URL and the edit would silently vanish.
    func flushSave(allowRename: Bool = true) async {
        saveTask?.cancel()
        guard dirty, let url = loadedURL else { return }
        do {
            try await store.writeString(noteText, to: url)
            dirty = false
            if allowRename {
                await renameToMatchTitle()
            }
        } catch {
            // Keep dirty; next debounce retries. Files are truth — never
            // drop edits silently.
        }
    }

    /// Obsidian-style title sync: when the note's first line is a heading,
    /// the file is named after it. Runs after each successful save.
    private func renameToMatchTitle() async {
        guard let url = loadedURL, let root, let currentId = selectedID,
              let title = Self.headingTitle(of: noteText) else { return }
        let sanitized = Self.sanitizeFileName(title)
        let current = url.deletingPathExtension().lastPathComponent
        guard !sanitized.isEmpty, sanitized != current else { return }
        let folder = url.deletingLastPathComponent()
        var name = sanitized + ".md"
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(sanitized) \(counter).md"
            counter += 1
        }
        let destination = folder.appendingPathComponent(name)
        do {
            try await store.move(from: url, to: destination)
            let newId = VaultPath.relativePath(of: destination, in: root)
            loadedURL = destination
            selectedID = newId
            openTabs = openTabs.map { $0 == currentId ? newId : $0 }
            recents = recents.map { $0 == currentId ? newId : $0 }
            UserDefaults.standard.set(recents, forKey: "recentNotes")
            apply(VaultEnumerator.snapshot(of: root))
        } catch {
            // Rename is cosmetic; the save above already succeeded.
        }
    }

    /// The first non-empty body line when it's a markdown heading.
    static func headingTitle(of text: String) -> String? {
        let document = MarkdownDocument(source: text)
        for line in splitLines(document.body) {
            let trimmed = strippingCarriageReturn(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix("#") else { return nil }
            let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    /// Filesystem- and sync-safe file name from a heading.
    static func sanitizeFileName(_ title: String) -> String {
        String(
            title.map { "/\\:?%*|\"<>".contains($0) ? "-" : $0 }
        )
        .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        .prefix(80)
        .trimmingCharacters(in: .whitespaces)
    }

    /// Copies an image into the vault's Attachments folder and returns a
    /// markdown-ready path (percent-encoded) relative to the selected
    /// note's folder — ready for `![alt](path)`.
    func attachImage(from source: URL) async -> String? {
        guard let root else { return nil }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try? await store.createFolder(at: attachments)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        var name = "\(base).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: attachments.appendingPathComponent(name).path) {
            name = "\(base) \(counter).\(ext)"
            counter += 1
        }
        do {
            try await store.copy(from: source, to: attachments.appendingPathComponent(name))
        } catch {
            return nil
        }
        let noteDepth = (selectedID ?? "").split(separator: "/").count - 1
        let up = String(repeating: "../", count: max(noteDepth, 0))
        let relative = up + "Attachments/" + name
        return relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
    }

    /// Opens (creating if needed) the daily note for `date` under Daily/.
    func openDailyNote(for date: Date = Date()) {
        guard let root else { return }
        Task {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let day = formatter.string(from: date)
            let relative = "Daily/\(day).md"
            let url = root.appendingPathComponent(relative)
            if !notes.contains(where: { $0.relativePath == relative }) {
                try? await store.createFolder(
                    at: root.appendingPathComponent("Daily", isDirectory: true)
                )
                let weekday = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                try? await store.writeString("# \(day)\n\(weekday)\n\n", to: url)
                apply(VaultEnumerator.snapshot(of: root))
            }
            await performSelect(relative)
        }
    }

    /// The date of the currently open daily note, if it is one.
    var openDailyNoteDate: Date? {
        guard let selectedID, selectedID.hasPrefix("Daily/"), selectedID.hasSuffix(".md")
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = String(selectedID.dropFirst("Daily/".count).dropLast(3))
        return formatter.date(from: day)
    }

    /// Copies picked files/folders INTO the vault: .md/.txt/.markdown files
    /// land at the root (uniquified); folders copy their whole note tree
    /// under the folder's name. Returns a status line for the UI.
    func importIntoVault(urls: [URL]) async -> String {
        guard let root else { return "Vault not ready" }
        var copied = 0
        var skipped = 0
        let noteExtensions: Set<String> = ["md", "markdown", "txt"]
        let existing = Set(notes.map(\.relativePath))

        func uniqueRelative(_ desired: String) -> String {
            guard existing.contains(desired) || FileManager.default
                .fileExists(atPath: root.appendingPathComponent(desired).path) else { return desired }
            let url = URL(fileURLWithPath: desired)
            let base = url.deletingPathExtension().relativePath
            let ext = url.pathExtension
            var counter = 2
            var candidate = "\(base) \(counter).\(ext)"
            while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                counter += 1
                candidate = "\(base) \(counter).\(ext)"
            }
            return candidate
        }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let base = url.lastPathComponent
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey]
                )
                while let item = enumerator?.nextObject() as? URL {
                    guard noteExtensions.contains(item.pathExtension.lowercased()),
                          (try? item.resourceValues(forKeys: [.isRegularFileKey]))?
                          .isRegularFile == true else { continue }
                    let relative = base + "/" + item.path
                        .replacingOccurrences(of: url.path + "/", with: "")
                    let destination = root.appendingPathComponent(uniqueRelative(relative))
                    do {
                        try await store.createFolder(at: destination.deletingLastPathComponent())
                        try await store.copy(from: item, to: destination)
                        copied += 1
                    } catch { skipped += 1 }
                }
            } else if noteExtensions.contains(url.pathExtension.lowercased()) {
                let destination = root.appendingPathComponent(uniqueRelative(url.lastPathComponent))
                do {
                    try await store.copy(from: url, to: destination)
                    copied += 1
                } catch { skipped += 1 }
            } else {
                skipped += 1
            }
        }
        apply(VaultEnumerator.snapshot(of: root))
        return skipped == 0
            ? "Imported \(copied) note\(copied == 1 ? "" : "s")"
            : "Imported \(copied), skipped \(skipped) (not markdown/text)"
    }

    /// Notes under Templates/ act as templates for new notes.
    var templates: [VaultItem] {
        notes.filter { $0.relativePath.hasPrefix("Templates/") }
    }

    /// New note from a template: placeholders expanded, name uniquified.
    func createNote(fromTemplate template: VaultItem) {
        guard let root else { return }
        Task {
            guard let raw = try? await store.readString(at: template.url) else { return }
            let base = URL(fileURLWithPath: template.relativePath)
                .deletingPathExtension().lastPathComponent
            let existing = Set(notes.map(\.relativePath))
            var title = base
            var counter = 2
            while existing.contains(title + ".md") {
                title = "\(base) \(counter)"
                counter += 1
            }
            let contents = TemplateExpansion.expand(raw, title: title)
            let url = root.appendingPathComponent(title + ".md")
            do {
                try await store.writeString(contents, to: url)
                apply(VaultEnumerator.snapshot(of: root))
                await performSelect(title + ".md")
            } catch {
                // Surfaced implicitly: note won't appear.
            }
        }
    }

    func createNote(in folder: String = "") {
        guard let root else { return }
        Task {
            let existing = Set(notes.map(\.relativePath))
            let prefix = folder.isEmpty ? "" : folder + "/"
            var name = prefix + "Untitled.md"
            var counter = 2
            while existing.contains(name) {
                name = prefix + "Untitled \(counter).md"
                counter += 1
            }
            let url = root.appendingPathComponent(name)
            do {
                let title = url.deletingPathExtension().lastPathComponent
                try await store.writeString("# \(title)\n\n", to: url)
                if let root = self.root {
                    apply(VaultEnumerator.snapshot(of: root))
                }
                await performSelect(VaultPath.relativePath(of: url, in: root))
            } catch {
                // Surfaced implicitly: note won't appear.
            }
        }
    }

    func closeTab(_ id: VaultItem.ID) {
        openTabs.removeAll { $0 == id }
        if selectedID == id {
            select(openTabs.last)
        }
    }

    func createFolder(named name: String, in parent: String = "") {
        guard let root else { return }
        let cleaned = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        guard !cleaned.isEmpty else { return }
        let path = parent.isEmpty ? cleaned : parent + "/" + cleaned
        Task {
            try? await store.createFolder(at: root.appendingPathComponent(path, isDirectory: true))
            if let root = self.root {
                apply(VaultEnumerator.snapshot(of: root))
            }
        }
    }

    /// Move a note into a folder ("" = vault root). Files are truth: this
    /// is a real coordinated move; tabs and selection follow the new id.
    func move(_ item: VaultItem, toFolder folder: String) {
        guard let root else { return }
        let name = item.relativePath.split(separator: "/").last.map(String.init) ?? item.relativePath
        let newRelative = folder.isEmpty ? name : folder + "/" + name
        guard newRelative != item.relativePath else { return }
        Task {
            await flushSave()
            do {
                try await store.move(from: item.url, to: root.appendingPathComponent(newRelative))
                if let index = openTabs.firstIndex(of: item.id) {
                    openTabs[index] = newRelative
                }
                if selectedID == item.id {
                    selectedID = newRelative
                }
                apply(VaultEnumerator.snapshot(of: root))
            } catch {
                // Move failed; list refresh will show reality.
            }
        }
    }

    func delete(_ item: VaultItem) {
        Task {
            if item.url == loadedURL {
                await performSelect(nil)
            }
            try? await store.delete(at: item.url)
            if let root {
                apply(VaultEnumerator.snapshot(of: root))
            }
        }
    }
}

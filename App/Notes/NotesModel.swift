import Foundation
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

    func start() async {
        guard !started else { return }
        started = true

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

    func select(_ id: VaultItem.ID?) {
        Task { await performSelect(id) }
    }

    private func performSelect(_ id: VaultItem.ID?) async {
        await flushSave()
        selectedID = id
        if let id {
            recents.removeAll { $0 == id }
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

    func flushSave() async {
        saveTask?.cancel()
        guard dirty, let url = loadedURL else { return }
        do {
            try await store.writeString(noteText, to: url)
            dirty = false
        } catch {
            // Keep dirty; next debounce retries. Files are truth — never
            // drop edits silently.
        }
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

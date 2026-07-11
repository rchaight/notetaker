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
    var selectedID: VaultItem.ID?
    var noteText = ""

    private(set) var root: URL?
    private let store = VaultFileStore()
    private var observer: MetadataQueryObserver?
    private var observation: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadedURL: URL?
    private var dirty = false

    func start() async {
        guard state == .loading else { return }
        do {
            let documents = try await UbiquityContainer.documentsURL()
            root = documents
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

    /// Markdown files only, stable order.
    private func apply(_ snapshot: [VaultItem]) {
        notes = snapshot
            .filter { !$0.isDirectory && $0.relativePath.lowercased().hasSuffix(".md") }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func select(_ id: VaultItem.ID?) {
        Task { await performSelect(id) }
    }

    private func performSelect(_ id: VaultItem.ID?) async {
        await flushSave()
        selectedID = id
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

    func createNote() {
        guard let root else { return }
        Task {
            let existing = Set(notes.map(\.relativePath))
            var name = "Untitled.md"
            var counter = 2
            while existing.contains(name) {
                name = "Untitled \(counter).md"
                counter += 1
            }
            let url = root.appendingPathComponent(name)
            do {
                try await store.writeString("# \(name.replacingOccurrences(of: ".md", with: ""))\n\n", to: url)
                if let root = self.root {
                    apply(VaultEnumerator.snapshot(of: root))
                }
                await performSelect(VaultPath.relativePath(of: url, in: root))
            } catch {
                // Surfaced implicitly: note won't appear.
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

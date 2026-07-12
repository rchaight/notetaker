import ConversionKit
import Foundation
import IndexKit
import MarkdownKit
import Observation
import TaskEngine
import VaultKit

/// The app-level pipeline: vault files → live derived index → outbound
/// checkbox writes. One instance shared by the To-Do tab (and later search,
/// projects, widgets). The vault is truth; this service only mirrors it.
///
/// Observation design: metadata-query / file-presenter events are TRIGGERS
/// only — every reindex re-enumerates the filesystem, which is authoritative.
/// (Metadata snapshots can be empty or partial — e.g. local vaults, or
/// mid-gathering — and must never drive pruning directly.)
@MainActor
@Observable
final class VaultIndexService {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    var state: State = .starting
    var isLocalFallback = false
    /// Bumped whenever indexed tasks may have changed — views refetch on it.
    var tasksVersion = 0

    private(set) var root: URL?
    let store = VaultFileStore()
    private var database: IndexDatabase?
    private var indexer: NoteIndexer?
    private var observer: MetadataQueryObserver?
    private var presenter: VaultPresenter?
    #if os(macOS)
        private var watcher: DirectoryWatcher?
    #endif
    private var observationTasks: [Task<Void, Never>] = []
    private var knownMTimes: [String: Date] = [:]
    private var started = false

    func start() async {
        // Multiple views call start(); only the first proceeds (the state
        // guard alone isn't enough — it doesn't flip until after awaits).
        guard !started else { return }
        started = true
        do {
            let resolved: URL
            do {
                resolved = try await UbiquityContainer.documentsURL()
            } catch {
                let local = try FileManager.default
                    .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("LocalVault", isDirectory: true)
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                isLocalFallback = true
                resolved = local
            }
            root = resolved

            let indexDir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Index", isDirectory: true)
            try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
            let (db, _) = try IndexDatabase.open(path: indexDir.appendingPathComponent("index.sqlite").path)
            database = db
            indexer = NoteIndexer(database: db)

            await reindexFromDisk()
            state = .ready
            startObservers(root: resolved)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        observer?.stop()
        presenter?.stop()
        #if os(macOS)
            watcher?.stop()
        #endif
        for task in observationTasks {
            task.cancel()
        }
    }

    private func startObservers(root: URL) {
        if isLocalFallback {
            let presenter = VaultPresenter(root: root)
            self.presenter = presenter
            observationTasks.append(Task { [weak self] in
                for await _ in presenter.changes {
                    await self?.reindexFromDisk()
                }
            })
            #if os(macOS)
                let watcher = DirectoryWatcher(root: root)
                self.watcher = watcher
                observationTasks.append(Task { [weak self] in
                    for await _ in watcher.events {
                        await self?.reindexFromDisk()
                    }
                })
            #endif
        } else {
            let observer = MetadataQueryObserver(root: root)
            self.observer = observer
            observationTasks.append(Task { [weak self] in
                for await _ in observer.snapshots() {
                    await self?.reindexFromDisk()
                }
            })
        }
    }

    /// Authoritative incremental sync from the real filesystem: mtime-moved
    /// files get re-read (the indexer's hash check catches touch-without-
    /// change), iCloud placeholders count as present and start downloading,
    /// vanished notes are pruned.
    private func reindexFromDisk() async {
        guard let indexer, let database, let root else { return }
        var changed = false
        var present = Set<String>()

        for item in VaultEnumerator.snapshot(of: root) where !item.isDirectory {
            let path = item.relativePath
            if path.lowercased().hasSuffix(".md") {
                present.insert(path)
                if let modified = item.modificationDate, knownMTimes[path] == modified {
                    continue
                }
                guard let contents = try? await store.readString(at: item.url) else { continue }
                let didChange = (try? indexer.index(
                    noteId: path, contents: contents, modifiedAt: item.modificationDate
                )) ?? false
                if let modified = item.modificationDate {
                    knownMTimes[path] = modified
                }
                changed = changed || didChange
            } else if let placeholder = Self.placeholderNoteId(path) {
                // Not-yet-downloaded ".Note.md.icloud": keep any indexed rows
                // and nudge the download along.
                present.insert(placeholder)
                try? store.startDownloading(item.url)
            }
        }

        if let indexed = try? database.indexedNoteIds() {
            for id in indexed where !present.contains(id) {
                try? indexer.remove(noteId: id)
                knownMTimes[id] = nil
                changed = true
            }
        }
        if changed {
            tasksVersion += 1
        }
    }

    /// ".Note.md.icloud" (possibly nested in folders) → "Note.md".
    static func placeholderNoteId(_ relativePath: String) -> String? {
        guard relativePath.hasSuffix(".icloud") else { return nil }
        var components = relativePath.split(separator: "/").map(String.init)
        guard var name = components.popLast(), name.hasPrefix(".") else { return nil }
        name = String(name.dropFirst().dropLast(".icloud".count))
        guard name.lowercased().hasSuffix(".md") else { return nil }
        return (components + [name]).joined(separator: "/")
    }

    func openTasks() -> [TaskRecord] {
        guard let database else { return [] }
        return (try? database.openTasks()) ?? []
    }

    func taskLabels() -> [String: [String]] {
        guard let database else { return [:] }
        return (try? database.labelsByTaskId()) ?? [:]
    }

    func subtaskProgress() -> [String: (done: Int, total: Int)] {
        guard let database else { return [:] }
        return (try? database.subtaskProgress()) ?? [:]
    }

    /// Imports an external document: convert on-device → write to
    /// Imports/<name>.md with provenance frontmatter → index. Returns the
    /// created note id, or nil with a reason string.
    func importFile(_ url: URL) async -> Result<String, String> {
        guard let root, let indexer else { return .failure("vault not ready") }
        let converter = NativeConverter()
        guard converter.canConvert(fileExtension: url.pathExtension) else {
            return .failure("\(url.pathExtension) needs the Docling tier (coming in this milestone)")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let result: ConversionResult
        do {
            result = try await converter.convert(url)
        } catch {
            return .failure("conversion failed: \(error)")
        }

        let importsDir = root.appendingPathComponent("Imports", isDirectory: true)
        var candidate = "Imports/\(result.suggestedName).md"
        var counter = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "Imports/\(result.suggestedName) \(counter).md"
            counter += 1
        }
        _ = importsDir // directory created by coordinated write below

        let stamp = ISO8601DateFormatter().string(from: Date())
        let contents = """
        ---
        imported-from: \(url.lastPathComponent)
        converted-by: \(result.provenance)
        imported: \(stamp)
        ---

        """ + result.markdown

        do {
            let destination = root.appendingPathComponent(candidate)
            try await store.writeString(contents, to: destination)
            try indexer.index(noteId: candidate, contents: contents, modifiedAt: nil)
            tasksVersion += 1
            return .success(candidate)
        } catch {
            return .failure("write failed: \(error.localizedDescription)")
        }
    }

    /// Quick Add: one parsed line appended to Inbox.md at the vault root.
    @discardableResult
    func quickAdd(_ input: String) async -> Bool {
        guard let root, let indexer,
              let result = QuickAddParser.parse(input) else { return false }
        let inbox = root.appendingPathComponent("Inbox.md")
        let existing = await (try? store.readString(at: inbox)) ?? "# Inbox\n"
        let updated = (existing.hasSuffix("\n") ? existing : existing + "\n")
            + result.markdownLine + "\n"
        do {
            try await store.writeString(updated, to: inbox)
            try indexer.index(noteId: "Inbox.md", contents: updated, modifiedAt: nil)
            knownMTimes["Inbox.md"] = nil
            tasksVersion += 1
            return true
        } catch {
            return false
        }
    }

    /// BM25-ranked note ids for a user-typed query. Terms are quoted and
    /// prefix-matched so FTS5 operator characters can't break the query.
    func searchNoteIds(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let database, !trimmed.isEmpty else { return [] }
        let sanitized = trimmed.split(separator: " ")
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        return (try? database.searchNoteIds(matching: sanitized)) ?? []
    }

    /// Master-list toggle: coordinated read → flip the source line (with
    /// drift protection) → coordinated write → re-index that note. When the
    /// line drifted, we re-index instead of writing — the row corrects
    /// itself and the user taps again.
    func toggle(_ task: TaskRecord) async {
        guard let root, let indexer else { return }
        let url = root.appendingPathComponent(task.noteId)
        guard let contents = try? await store.readString(at: url) else { return }

        let updated: String? = if task.recurrence != nil {
            // Recurring: completing = advancing the date, box stays open.
            if let line = TaskLineToggler.locate(
                contents: contents, anchorLine: task.line, expectedRawLine: task.rawLine
            ), let completedLine = RecurrenceEngine.completeTaskLine(task.rawLine) {
                TaskLineToggler.replacingLine(contents, at: line, with: completedLine)
            } else {
                nil
            }
        } else {
            TaskLineToggler.toggle(
                contents: contents, anchorLine: task.line, expectedRawLine: task.rawLine
            )?.contents
        }

        if let updated {
            try? await store.writeString(updated, to: url)
            try? indexer.index(noteId: task.noteId, contents: updated, modifiedAt: nil)
        } else {
            try? indexer.index(noteId: task.noteId, contents: contents, modifiedAt: nil)
        }
        knownMTimes[task.noteId] = nil
        tasksVersion += 1
    }
}

import AIKit
import ConversionKit
import Foundation
import IndexKit
import MarkdownKit
import Observation
import SecurityKit
import TaskEngine
import VaultKit
import WidgetKit

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
    private let embeddings = AppleEmbeddingProvider()
    private var embeddingTasks: [String: Task<Void, Never>] = [:]

    func start() async {
        // Multiple views call start(); only the first proceeds (the state
        // guard alone isn't enough — it doesn't flip until after awaits).
        guard !started else { return }
        started = true
        do {
            let resolved: URL
            if let custom = VaultRegistry.activeCustomRoot() {
                // Custom folder vault: local observers, per-vault index.
                resolved = custom
                isLocalFallback = true
            } else {
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
            }
            root = resolved

            let indexDir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Index", isDirectory: true)
            try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
            let indexName = VaultRegistry.activeId == VaultRegistry.iCloudId
                ? "index.sqlite" : "index-\(VaultRegistry.activeId).sqlite"
            let (db, _) = try IndexDatabase.open(path: indexDir.appendingPathComponent(indexName).path)
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

    /// Files the user (or the share sheet, or another device) dropped into
    /// Imports/Inbox — anything non-markdown there gets converted on scan.
    private var inboxFailures: Set<String> = []

    /// Authoritative incremental sync from the real filesystem: mtime-moved
    /// files get re-read (the indexer's hash check catches touch-without-
    /// change), iCloud placeholders count as present and start downloading,
    /// vanished notes are pruned. Inbox drops get converted.
    private func reindexFromDisk() async {
        guard let indexer, let database, let root else { return }
        var changed = false
        var present = Set<String>()

        for item in VaultEnumerator.snapshot(of: root) where !item.isDirectory {
            let path = item.relativePath
            if path.hasPrefix("Imports/Inbox/"), !path.lowercased().hasSuffix(".md"),
               !path.hasSuffix(".icloud"), !inboxFailures.contains(path) {
                // The import-inbox: convert the drop, then consume it. On
                // failure leave it (a Mac with the Docling server picks it
                // up on a later scan — this IS the iOS→Mac relay).
                switch await importFile(item.url) {
                case .success:
                    try? await store.delete(at: item.url)
                    changed = true
                case .failure:
                    inboxFailures.insert(path) // retry next launch
                }
                continue
            }
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
                if didChange {
                    scheduleEmbedding(noteId: path, contents: contents)
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
        // Always bump: views key their queries on this counter, and the
        // FIRST scan after launch must refresh them even when no file
        // changed (favorites/pins read the db before it opened otherwise).
        tasksVersion += 1
        publishWidgetSnapshot()
    }

    /// Today-tasks snapshot for the widget, via the app-group container.
    /// Fails silently when the group isn't provisioned (ad-hoc dev builds).
    private func publishWidgetSnapshot() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "6A2NHN89Q8.com.rchaight.notetaker"
        ) else { return }
        let open = (try? database?.openTasks()) ?? []
        let buckets = Dictionary(grouping: open) {
            SmartBuckets.bucket(dueDate: $0.dueDate, startDate: $0.startDate)
        }
        let today = buckets[.today] ?? []
        let payload: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "todayCount": today.count,
            "overdueCount": (buckets[.overdue] ?? []).count,
            "items": today.prefix(6).map {
                ["id": $0.id, "text": $0.text, "priority": $0.priority as Any]
            },
        ]
        // Encodable via JSONSerialization keeps the widget's Codable shape
        // without sharing a module.
        struct Item: Codable { let id: String; let text: String; let priority: Int? }
        struct Snapshot: Codable {
            let updated: Date
            let todayCount: Int
            let overdueCount: Int
            let items: [Item]
        }
        _ = payload
        let snapshot = Snapshot(
            updated: Date(),
            todayCount: today.count,
            overdueCount: (buckets[.overdue] ?? []).count,
            items: today.prefix(6).map {
                Item(id: $0.id, text: $0.text, priority: $0.priority)
            }
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: container.appendingPathComponent("today-tasks.json"))
            #if canImport(WidgetKit)
                WidgetCenter.shared.reloadTimelines(ofKind: "TodayTasks")
            #endif
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

    struct ImportError: Error {
        let message: String
    }

    /// Imports an external document: route to the best tier (on-device
    /// native → local File-Parser engine → docling-serve) → write to
    /// Imports/<name>.md with provenance frontmatter → index.
    func importFile(_ url: URL) async -> Result<String, ImportError> {
        guard let root, let indexer else { return .failure(ImportError(message: "vault not ready")) }
        let serverURL = UserDefaults.standard.string(forKey: "doclingServeURL")
            .flatMap(ServerURL.normalize)
        let router = ConversionRouter(doclingServeURL: serverURL)
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let result: ConversionResult
        do {
            result = try await router.convert(url)
        } catch let ConversionError.failed(message) {
            return .failure(ImportError(message: message))
        } catch let ConversionError.unsupportedType(ext) {
            return .failure(ImportError(message: "no converter for .\(ext)"))
        } catch {
            return .failure(ImportError(message: "conversion failed: \(error)"))
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
            return .failure(ImportError(message: "write failed: \(error.localizedDescription)"))
        }
    }

    /// Quick Add: one parsed line appended to Inbox.md at the vault root.
    @discardableResult
    func quickAdd(_ input: String) async -> Bool {
        guard let root, let indexer else { return false }
        guard let line = await Self.quickAddLine(for: input) else { return false }
        let inbox = root.appendingPathComponent("Inbox.md")
        let existing = await (try? store.readString(at: inbox)) ?? "# Inbox\n"
        let updated = (existing.hasSuffix("\n") ? existing : existing + "\n")
            + line + "\n"
        do {
            try await store.writeString(updated, to: inbox)
            try indexer.index(noteId: "Inbox.md", contents: updated, modifiedAt: nil)
            knownMTimes["Inbox.md"] = nil
            tasksVersion += 1
            onNoteMutated?("Inbox.md")
            return true
        } catch {
            return false
        }
    }

    /// Natural-language parse for Quick Add: on-device Apple Intelligence
    /// first (guided generation understands "report every monday 10am"),
    /// falling back to the deterministic token parser. Inputs that already
    /// carry explicit grammar tokens skip the model — the token parser is
    /// exact and free.
    static func quickAddLine(for input: String) async -> String? {
        let hasExplicitTokens = input.contains(">") || input.contains("!p")
            || input.contains("&every") || input.contains("&after")
        if !hasExplicitTokens {
            var providers: [any AIProvider] = []
            #if canImport(FoundationModels)
                providers.append(FoundationModelsProvider())
            #endif
            let router = AIRouter(providers: providers)
            if let task = try? await router.parseTask(input) {
                let line = task.markdownLine
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    return line
                }
            }
        }
        return QuickAddParser.parse(input)?.markdownLine
    }

    /// Off the hot path: chunk + embed a changed note and store vectors.
    private func scheduleEmbedding(noteId: String, contents: String) {
        embeddingTasks[noteId]?.cancel()
        embeddingTasks[noteId] = Task { [weak self] in
            guard let self, await embeddings.isAvailable(), let database else { return }
            let body = MarkdownDocument(source: contents).body
            let chunks = EmbeddingChunker.chunks(from: body)
            guard !chunks.isEmpty, !Task.isCancelled else { return }
            guard let vectors = try? await embeddings.embed(chunks), !Task.isCancelled else { return }
            try? database.replaceChunks(
                noteId: noteId,
                chunks: Array(zip(chunks, vectors).map { ($0, $1) })
            )
        }
    }

    /// Reschedule: rewrite the source line's >due (and optionally ~start)
    /// tokens — same locate→rewrite→coordinated-write→reindex shape as
    /// toggle, with the same drift protection.
    func reschedule(
        _ task: TaskRecord, due: String?, start: String?? = nil
    ) async {
        guard let root, let indexer else { return }
        await beforeNoteMutation?(task.noteId)
        let url = root.appendingPathComponent(task.noteId)
        guard let contents = try? await store.readString(at: url),
              let line = TaskLineToggler.locate(
                  contents: contents, anchorLine: task.line, expectedRawLine: task.rawLine
              )
        else {
            try? await indexer.index(
                noteId: task.noteId,
                contents: (try? store.readString(at: url)) ?? "",
                modifiedAt: nil
            )
            tasksVersion += 1
            return
        }
        var rewritten = TaskLineRewriter.settingDueDate(task.rawLine, to: due)
        if case let .some(newStart) = start {
            rewritten = TaskLineRewriter.settingStartDate(rewritten, to: newStart)
        }
        guard rewritten != task.rawLine else { return }
        let updated = TaskLineToggler.replacingLine(contents, at: line, with: rewritten)
        try? await store.writeString(updated, to: url)
        try? indexer.index(noteId: task.noteId, contents: updated, modifiedAt: nil)
        knownMTimes[task.noteId] = nil
        tasksVersion += 1
        onNoteMutated?(task.noteId)
    }

    /// Generic single-line rewrite with the full outbound-write discipline.
    func rewriteTaskLine(_ task: TaskRecord, transform: (String) -> String) async {
        guard let root, let indexer else { return }
        await beforeNoteMutation?(task.noteId)
        let url = root.appendingPathComponent(task.noteId)
        guard let contents = try? await store.readString(at: url),
              let line = TaskLineToggler.locate(
                  contents: contents, anchorLine: task.line, expectedRawLine: task.rawLine
              )
        else { return }
        let rewritten = transform(task.rawLine)
        guard rewritten != task.rawLine else { return }
        let updated = TaskLineToggler.replacingLine(contents, at: line, with: rewritten)
        try? await store.writeString(updated, to: url)
        try? indexer.index(noteId: task.noteId, contents: updated, modifiedAt: nil)
        knownMTimes[task.noteId] = nil
        tasksVersion += 1
        onNoteMutated?(task.noteId)
    }

    func setPriority(_ task: TaskRecord, priority: Int?) async {
        await rewriteTaskLine(task) { TaskLineRewriter.settingPriority($0, to: priority) }
    }

    func addLabel(_ task: TaskRecord, label: String) async {
        await rewriteTaskLine(task) { TaskLineRewriter.addingLabel($0, label: label) }
    }

    /// Deletes the task's source line (swipe-delete). Drift-protected like
    /// every outbound write: wrong anchor → reindex instead of destroying
    /// an unrelated line.
    func deleteTask(_ task: TaskRecord) async {
        guard let root, let indexer else { return }
        await beforeNoteMutation?(task.noteId)
        let url = root.appendingPathComponent(task.noteId)
        guard let contents = try? await store.readString(at: url) else { return }
        guard let line = TaskLineToggler.locate(
            contents: contents, anchorLine: task.line, expectedRawLine: task.rawLine
        ) else {
            try? indexer.index(noteId: task.noteId, contents: contents, modifiedAt: nil)
            tasksVersion += 1
            return
        }
        let updated = TaskLineToggler.removingLine(contents, at: line)
        try? await store.writeString(updated, to: url)
        try? indexer.index(noteId: task.noteId, contents: updated, modifiedAt: nil)
        knownMTimes[task.noteId] = nil
        tasksVersion += 1
        onNoteMutated?(task.noteId)
    }

    /// "Blocked by": gives `target` a ^block-id when needed and appends
    /// blockedby:^id to `dependent`. Both lines live in the same note; one
    /// read→rewrite→write pass keeps it atomic.
    func addDependency(dependent: TaskRecord, target: TaskRecord) async {
        guard let root, let indexer, dependent.noteId == target.noteId,
              dependent.id != target.id else { return }
        await beforeNoteMutation?(dependent.noteId)
        let url = root.appendingPathComponent(dependent.noteId)
        guard var contents = try? await store.readString(at: url),
              let targetLine = TaskLineToggler.locate(
                  contents: contents, anchorLine: target.line, expectedRawLine: target.rawLine
              )
        else { return }
        let (newTargetLine, blockId) = TaskLineRewriter.ensuringBlockId(target.rawLine)
        if newTargetLine != target.rawLine {
            contents = TaskLineToggler.replacingLine(contents, at: targetLine, with: newTargetLine)
        }
        guard let dependentLine = TaskLineToggler.locate(
            contents: contents, anchorLine: dependent.line, expectedRawLine: dependent.rawLine
        ) else { return }
        let newDependentLine = TaskLineRewriter.addingDependency(dependent.rawLine, on: blockId)
        guard newDependentLine != dependent.rawLine || newTargetLine != target.rawLine
        else { return }
        contents = TaskLineToggler.replacingLine(contents, at: dependentLine, with: newDependentLine)
        try? await store.writeString(contents, to: url)
        try? indexer.index(noteId: dependent.noteId, contents: contents, modifiedAt: nil)
        knownMTimes[dependent.noteId] = nil
        tasksVersion += 1
        onNoteMutated?(dependent.noteId)
    }

    /// Creates a project note (frontmatter-marked) at the vault root and
    /// returns its noteId.
    func createProject(named name: String) async -> String? {
        guard let root, let indexer else { return nil }
        let base = name.trimmingCharacters(in: .whitespaces)
        let title = base.isEmpty ? "New Project" : base
        let fileName = VaultNaming.uniqueFileName(base: title, ext: "md", in: root)
        let contents = """
        ---
        project: true
        status: active
        ---
        # \(title)

        - [ ] first task

        """
        let url = root.appendingPathComponent(fileName)
        do {
            try await store.writeString(contents, to: url)
            try indexer.index(noteId: fileName, contents: contents, modifiedAt: nil)
            knownMTimes[fileName] = nil
            tasksVersion += 1
            onNoteMutated?(fileName)
            return fileName
        } catch {
            return nil
        }
    }

    /// Whether a note currently carries the project flag.
    func isProject(_ noteId: String) -> Bool {
        projects().contains { $0.id == noteId }
    }

    /// Guarantees the task line carries a durable ^id (the CloudKit link
    /// key) and returns it. Existing ids are reused; assignment is lazy —
    /// only tasks with extended data ever gain one.
    func ensureStableId(_ task: TaskRecord) async -> String? {
        if let existing = task.blockId {
            return existing
        }
        // Slug from the text plus entropy: ids must survive text edits AND
        // never collide within the note.
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let (_, id) = TaskLineRewriter.ensuringBlockId(
            task.rawLine, preferred: "t-" + suffix
        )
        await rewriteTaskLine(task) { line in
            TaskLineRewriter.ensuringBlockId(line, preferred: "t-" + suffix).line
        }
        return id
    }

    /// Moves a task's line into another note (assign to project). The raw
    /// line moves verbatim — tokens, ^id, and therefore CloudKit extras all
    /// follow. Drift-protected on the source side.
    func moveTask(_ task: TaskRecord, toNote destinationId: String) async -> Bool {
        guard let root, let indexer, task.noteId != destinationId else { return false }
        await beforeNoteMutation?(task.noteId)
        let sourceURL = root.appendingPathComponent(task.noteId)
        let destinationURL = root.appendingPathComponent(destinationId)
        guard let source = try? await store.readString(at: sourceURL),
              let line = TaskLineToggler.locate(
                  contents: source, anchorLine: task.line, expectedRawLine: task.rawLine
              ),
              let destination = try? await store.readString(at: destinationURL)
        else { return false }
        // Destination first: if it fails, the task is still in its source.
        let movedLine = task.rawLine.hasSuffix("\r")
            ? String(task.rawLine.dropLast()) : task.rawLine
        let appended = (destination.hasSuffix("\n") ? destination : destination + "\n")
            + movedLine + "\n"
        do {
            try await store.writeString(appended, to: destinationURL)
            let trimmed = TaskLineToggler.removingLine(source, at: line)
            try await store.writeString(trimmed, to: sourceURL)
            try indexer.index(noteId: destinationId, contents: appended, modifiedAt: nil)
            try indexer.index(noteId: task.noteId, contents: trimmed, modifiedAt: nil)
            knownMTimes[task.noteId] = nil
            knownMTimes[destinationId] = nil
            tasksVersion += 1
            onNoteMutated?(task.noteId)
            onNoteMutated?(destinationId)
            return true
        } catch {
            return false
        }
    }

    /// Appends a task line to a note (project detail's add-task field).
    /// Input goes through the ONE quick-add grammar.
    func addTask(to noteId: String, input: String) async -> Bool {
        guard let root, let indexer,
              let line = await Self.quickAddLine(for: input) else { return false }
        await beforeNoteMutation?(noteId)
        let url = root.appendingPathComponent(noteId)
        guard let contents = try? await store.readString(at: url) else { return false }
        let updated = (contents.hasSuffix("\n") ? contents : contents + "\n") + line + "\n"
        do {
            try await store.writeString(updated, to: url)
            try indexer.index(noteId: noteId, contents: updated, modifiedAt: nil)
            knownMTimes[noteId] = nil
            tasksVersion += 1
            onNoteMutated?(noteId)
            return true
        } catch {
            return false
        }
    }

    /// Manual full rescan (Vault tab toolbar).
    func rescan() async {
        await reindexFromDisk()
    }

    var vaultRootURL: URL? {
        root
    }

    func projects() -> [NoteRecord] {
        (try? database?.projects()) ?? []
    }

    func noteTaskProgress() -> [String: (done: Int, total: Int)] {
        (try? database?.noteTaskProgress()) ?? [:]
    }

    func tasks(inNote noteId: String) -> [TaskRecord] {
        (try? database?.tasks(inNote: noteId)) ?? []
    }

    func favoriteNoteIds() -> [String] {
        (try? database?.favoriteNoteIds()) ?? []
    }

    func completedTasks() -> [TaskRecord] {
        (try? database?.completedTasks()) ?? []
    }

    func pinnedNoteIds() -> [String] {
        (try? database?.pinnedNoteIds()) ?? []
    }

    func bookmarkedNoteIds() -> [String] {
        (try? database?.bookmarkedNoteIds()) ?? []
    }

    /// Reads one frontmatter value from the note file.
    func frontmatterValue(_ noteId: String, key: String) async -> String? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(noteId)
        guard let contents = try? await store.readString(at: url) else { return nil }
        return MarkdownDocument(source: contents).frontmatter?.values[key]
    }

    /// Writes one frontmatter string value (nil removes the key).
    func setFrontmatterValue(_ noteId: String, key: String, value: String?) async {
        guard let root, let indexer else { return }
        await beforeNoteMutation?(noteId)
        let url = root.appendingPathComponent(noteId)
        guard let contents = try? await store.readString(at: url) else { return }
        let document = MarkdownDocument(source: contents)
        let frontmatter = (document.frontmatter ?? Frontmatter(values: [:]))
            .updating(key: key, value: value)
        let updated = MarkdownDocument(frontmatter: frontmatter, body: document.body).render()
        guard updated != contents else { return }
        try? await store.writeString(updated, to: url)
        try? indexer.index(noteId: noteId, contents: updated, modifiedAt: nil)
        knownMTimes[noteId] = nil
        tasksVersion += 1
        onNoteMutated?(noteId)
    }

    /// Flags live in the note's frontmatter (files are truth; they sync).
    func setNoteFlag(_ noteId: String, key: String, value: Bool) async {
        guard let root, let indexer else { return }
        await beforeNoteMutation?(noteId)
        let url = root.appendingPathComponent(noteId)
        guard let contents = try? await store.readString(at: url) else { return }
        let document = MarkdownDocument(source: contents)
        let frontmatter = (document.frontmatter ?? Frontmatter(values: [:]))
            .updating(key: key, value: value ? "true" : nil)
        let updated = MarkdownDocument(frontmatter: frontmatter, body: document.body).render()
        guard updated != contents else { return }
        try? await store.writeString(updated, to: url)
        try? indexer.index(noteId: noteId, contents: updated, modifiedAt: nil)
        knownMTimes[noteId] = nil
        tasksVersion += 1
        onNoteMutated?(noteId)
    }

    /// Renames #from → #to in every note carrying the EXACT tag (nested
    /// children like #from/x are untouched — the boundary guard excludes
    /// them). Merge = rename onto an existing tag.
    func renameTag(from: String, to: String) async {
        guard let root, let indexer, let database, from != to, !to.isEmpty else { return }
        let pattern = "(?<=^|\\s)#" + NSRegularExpression.escapedPattern(for: from) + "(?![\\w/-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ids = (try? database.noteIds(withTag: from)) ?? []
        let replacement = "#" + NSRegularExpression.escapedTemplate(for: to)
        for id in ids {
            await beforeNoteMutation?(id)
            let url = root.appendingPathComponent(id)
            guard let contents = try? await store.readString(at: url) else { continue }
            let range = NSRange(location: 0, length: (contents as NSString).length)
            let updated = regex.stringByReplacingMatches(
                in: contents, range: range, withTemplate: replacement
            )
            guard updated != contents else { continue }
            try? await store.writeString(updated, to: url)
            try? indexer.index(noteId: id, contents: updated, modifiedAt: nil)
            knownMTimes[id] = nil
            onNoteMutated?(id)
        }
        tasksVersion += 1
    }

    /// Strips #tag (exact) from every note carrying it.
    func deleteTag(_ tag: String) async {
        guard let root, let indexer, let database else { return }
        let pattern = " ?#" + NSRegularExpression.escapedPattern(for: tag) + "(?![\\w/-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ids = (try? database.noteIds(withTag: tag)) ?? []
        for id in ids {
            await beforeNoteMutation?(id)
            let url = root.appendingPathComponent(id)
            guard let contents = try? await store.readString(at: url) else { continue }
            let range = NSRange(location: 0, length: (contents as NSString).length)
            let updated = regex.stringByReplacingMatches(in: contents, range: range, withTemplate: "")
            guard updated != contents else { continue }
            try? await store.writeString(updated, to: url)
            try? indexer.index(noteId: id, contents: updated, modifiedAt: nil)
            knownMTimes[id] = nil
            onNoteMutated?(id)
        }
        tasksVersion += 1
    }

    /// Merge suggestions: heuristics always; Ollama's semantic layer when
    /// configured (validated — never trusted to name real tags).
    func suggestTagMerges() async -> [TagMerge] {
        let tags = noteTags()
        guard !tags.isEmpty else { return [] }
        if let urlString = KeychainStore.read(account: "ollamaURL"),
           let url = ServerURL.normalize(urlString) {
            let model = UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3"
            let provider = OllamaProvider(baseURL: url, model: model.isEmpty ? "qwen3" : model)
            if await provider.isAvailable(),
               let merges = try? await provider.suggestTagMerges(tags: tags) {
                return merges
            }
        }
        return TagCuration.heuristicMerges(tags: tags)
    }

    func tasksWithLabel(_ label: String) -> [TaskRecord] {
        (try? database?.tasks(withLabel: label)) ?? []
    }

    /// Grouping suggestions: Ollama's semantic families when configured,
    /// prefix heuristics otherwise.
    func suggestTagGroups() async -> [TagGroup] {
        let tags = noteTags()
        guard !tags.isEmpty else { return [] }
        if let urlString = KeychainStore.read(account: "ollamaURL"),
           let url = ServerURL.normalize(urlString) {
            let model = UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3"
            let provider = OllamaProvider(baseURL: url, model: model.isEmpty ? "qwen3" : model)
            if await provider.isAvailable(),
               let groups = try? await provider.suggestTagGroups(tags: tags) {
                return groups
            }
        }
        return TagCuration.heuristicGroups(tags: tags)
    }

    func noteTags() -> [(tag: String, count: Int)] {
        (try? database?.tagsWithCounts()) ?? []
    }

    func tagNoteIds(_ tag: String) -> [String] {
        (try? database?.noteIds(withTag: tag)) ?? []
    }

    func allOutLinks() -> [(from: String, toTitle: String)] {
        (try? database?.allOutLinks()) ?? []
    }

    func backlinks(toTitle title: String) -> [String] {
        guard let database else { return [] }
        return (try? database.backlinks(toTitle: title)) ?? []
    }

    func unlinkedMentions(ofTitle title: String, excluding noteId: String) -> [String] {
        guard let database else { return [] }
        return (try? database.unlinkedMentions(ofTitle: title, excluding: noteId)) ?? []
    }

    /// Meaning-based note lookup; empty when embeddings are unavailable.
    func semanticSearchNoteIds(_ query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let database, trimmed.count > 2, await embeddings.isAvailable(),
              let vector = try? await embeddings.embed([trimmed]).first
        else { return [] }
        let results = (try? database.semanticSearch(query: vector, limit: 8)) ?? []
        return results.filter { $0.score > 0.45 }.map(\.noteId)
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
    /// Fired after this service rewrites a note file (to-do toggle, quick
    /// add) so an open editor can refresh — files are truth, and the note
    /// on screen must show them.
    var onNoteMutated: ((String) -> Void)?
    /// Awaited BEFORE this service rewrites a note file: the editor flushes
    /// pending keystrokes so the read below sees them — otherwise the
    /// debounced autosave fires moments later and silently reverts the
    /// mutation (user-reported as "Make Project does nothing").
    var beforeNoteMutation: ((String) async -> Void)?

    func toggle(_ task: TaskRecord) async {
        guard let root, let indexer else { return }
        await beforeNoteMutation?(task.noteId)
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
                contents: contents, anchorLine: task.line, expectedRawLine: task.rawLine,
                completionDay: TodoView.todayISO()
            )?.contents
        }

        if let updated {
            try? await store.writeString(updated, to: url)
            try? indexer.index(noteId: task.noteId, contents: updated, modifiedAt: nil)
            onNoteMutated?(task.noteId)
        } else {
            try? indexer.index(noteId: task.noteId, contents: contents, modifiedAt: nil)
        }
        knownMTimes[task.noteId] = nil
        tasksVersion += 1
    }
}

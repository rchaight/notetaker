import CryptoKit
import Foundation
import MarkdownKit
import Observation
import SecurityKit
import VaultKit

/// Sidebar state that must outlive a tab switch (the Notes tab is unmounted while another tab
/// shows, which used to reset it) but not a relaunch. Lives on `NotesModel`, which `AppShell`
/// owns, so it survives exactly as long as the selection and open tabs do.
struct SidebarState: Equatable {
    var searchText = ""
    var selectedTag: String?
    var tagsExpanded = false
    /// List selection for VAULT rows only; decoupled from `selectedID` so a click in
    /// Favorites/Recents highlights THAT row instead.
    var listSelection: String?
    /// "section|noteId" of the clicked section row, nil when the Vault list owns the highlight.
    var sectionHighlight: String?
}

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

    /// Derived lookups, rebuilt once per `apply` rather than per SwiftUI body
    /// pass. The list view asks for these many times per render (favorites,
    /// recents, pinned, every folder group); recomputing them inline made
    /// scrolling and selection visibly lag on a large vault.
    /// Every note keyed by id.
    private(set) var notesById: [VaultItem.ID: VaultItem] = [:]
    /// Notes grouped by their containing folder ("" = vault root).
    private(set) var notesByFolder: [String: [VaultItem]] = [:]
    /// `notes` pre-sorted newest-first, for the "Recently modified" order.
    private(set) var notesByModified: [VaultItem] = []
    /// Bumped whenever a refresh finishes, so views can react.
    private(set) var lastRefresh: Date?
    /// True while a manual/periodic refresh is in flight (drives the spinner).
    private(set) var refreshing = false
    /// Open note tabs, in open order (selection switches, ✕ closes).
    var openTabs: [VaultItem.ID] = []
    var selectedID: VaultItem.ID?
    var noteText = ""
    var sidebar = SidebarState()

    private(set) var root: URL?
    /// The most recent Move to Trash, for the Undo toast. The view clears it (via
    /// `dismissTrashNotice`) when the toast times out; Undo clears it itself.
    private(set) var lastTrashed: VaultTrash.Receipt?
    /// Why the last trash or undo failed, for a transient message. Nil otherwise.
    private(set) var trashFailure: String?
    /// Unlocked locked-notes this session: noteId → (key, envelope params).
    /// In memory only; quitting relocks everything.
    private var unlockedKeys = UnlockedKeyring()
    /// The locked note currently displayed as a placeholder (drives UI).
    private(set) var lockedPlaceholder = false

    /// Recently opened notes, newest first (device-local UI state).
    private(set) var recents: [String] =
        UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []
    /// Recents AS DISPLAYED. The live list gains an entry the instant a note
    /// opens, and because the Recents section sits above the vault list that
    /// inserts a row and shifts every row below down by exactly one — so the
    /// next click lands on the neighbour (user-reported "opens the wrong
    /// note"). The displayed copy only catches up once clicking has stopped.
    private(set) var displayedRecents: [String] =
        UserDefaults.standard.stringArray(forKey: "recentNotes") ?? []
    private var recentsSettleTask: Task<Void, Never>?
    private let store = VaultFileStore()
    private var observer: MetadataQueryObserver?
    private var observation: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadedURL: URL?
    private var dirty = false

    private var started = false
    /// UserDefaults hint for the note to reopen at launch (macOS). Never trusted: it is checked
    /// against the vault listing on use, so a trashed, moved or other-vault note is not restored.
    static let lastSelectedNoteKey = "ui.notes.lastSelectedNote"
    #if os(macOS)
        private var watcher: DirectoryWatcher?
        /// Set once a restore has actually looked at a non-empty vault listing.
        private var restoreSettled = false
    #endif

    func start() async {
        guard !started else { return }
        started = true

        #if os(macOS)
            if let custom = VaultRegistry.activeCustomRoot() {
                root = custom
                apply(VaultEnumerator.snapshot(of: custom))
                markReady(.ready)
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
            markReady(.ready)
        }

        do {
            let documents = try await UbiquityContainer.documentsURL()
            root = documents
            UserDefaults.standard.set(documents.path, forKey: "lastVaultRoot")
            apply(VaultEnumerator.snapshot(of: documents))
            markReady(.ready)

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
                markReady(.readyLocalFallback)
            } catch {
                state = .unavailable("No vault available: \(error.localizedDescription)")
            }
        }
    }

    /// Every path that makes the vault usable ends here. On the Mac it also reopens the note the
    /// app was quit on; that runs off to the side so a slow note read never holds up `start()`.
    private func markReady(_ ready: VaultState) {
        state = ready
        #if os(macOS)
            Task { await restoreLastSelection() }
        #endif
    }

    #if os(macOS)
        /// Reopens the last-selected note at launch (spec ux-phase2/03). The key is only a hint:
        /// it must name a note that is in the listing now and not under a hidden folder (`.trash/`),
        /// otherwise nothing is restored and the stale key is dropped. A locked note comes back as
        /// its placeholder (no key in memory), which is correct. Skipped when the user already
        /// picked something. An empty listing is not evidence the note is gone (a cold iCloud
        /// start can list nothing yet), so it neither restores nor discards; the next `markReady`
        /// tries again.
        private func restoreLastSelection() async {
            guard !restoreSettled else { return }
            guard selectedID == nil else {
                restoreSettled = true
                return
            }
            guard !notes.isEmpty else { return }
            restoreSettled = true
            let defaults = UserDefaults.standard
            guard let id = defaults.string(forKey: Self.lastSelectedNoteKey) else { return }
            guard !VaultPath.isInsideHiddenFolder(id), notesById[id] != nil else {
                defaults.removeObject(forKey: Self.lastSelectedNoteKey)
                return
            }
            await performSelect(id)
        }
    #endif

    /// Remembers the open note for the next launch (macOS), or forgets it when nothing is open.
    private func rememberSelection(_ id: String?) {
        #if os(macOS)
            if let id {
                UserDefaults.standard.set(id, forKey: Self.lastSelectedNoteKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSelectedNoteKey)
            }
        #endif
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
        let incoming = snapshot
            .filter { !$0.isDirectory && $0.relativePath.lowercased().hasSuffix(".md") }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        // Identical snapshots arrive constantly (every watcher tick, every
        // periodic refresh). Reassigning would churn the List and can yank a
        // row out from under an in-flight click, so only publish real changes.
        // Folders are still recomputed below — an empty new folder changes
        // the tree without changing any note.
        if incoming != notes {
            notes = incoming
            rebuildLookups()
        }
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
        let incomingFolders = seen.filter { !$0.isEmpty }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        // Same reason as above: @Observable notifies on every assignment,
        // equal value or not, and a churned folder list re-renders the tree.
        if incomingFolders != folders {
            folders = incomingFolders
        }
        openTabs.removeAll { id in !notes.contains { $0.id == id } }
    }

    /// Lets the Recents section catch up only after clicking has settled, so
    /// the list never grows a row while the user is still aiming at it.
    private func scheduleRecentsSettle() {
        recentsSettleTask?.cancel()
        recentsSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            if displayedRecents != recents {
                displayedRecents = recents
            }
        }
    }

    private func rebuildLookups() {
        // Ids are unique by construction (relative paths), but a trapping
        // initializer turns any future enumeration slip into a crash.
        notesById = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        notesByFolder = Dictionary(grouping: notes) {
            $0.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        }
        // `notes` is sorted by path ascending, so a grouped folder is too. Daily notes are named
        // by date: the newest goes on top.
        for folder in notesByFolder.keys where VaultPath.isDailyFolder(folder) {
            notesByFolder[folder]?.reverse()
        }
        notesByModified = notes.sorted {
            ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast)
        }
    }

    /// Re-reads the vault from disk and asks iCloud to materialize anything
    /// that is a placeholder or known-stale, so "refresh" really does pull
    /// from the server rather than just re-listing what is already local.
    func refresh() async {
        guard let root, !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            lastRefresh = Date()
        }
        let snapshot = VaultEnumerator.snapshot(of: root)
        for item in snapshot where !item.isDirectory && item.downloadState != .current {
            try? store.startDownloading(item.url)
        }
        apply(snapshot)
    }

    /// Cross-tab jump: open a note and remember the source line so the
    /// editor can scroll to it once the text is loaded.
    private(set) var pendingJumpLine: Int?

    /// A wikilink's `#Heading` / `#^block` anchor, resolved to a line by the view once the
    /// target's text is loaded (spec ux-phase2/06).
    private(set) var pendingJumpAnchor: (heading: String?, blockId: String?)?

    func openNote(_ id: String, jumpToLine line: Int?) {
        pendingJumpLine = line
        pendingJumpAnchor = nil
        select(id)
    }

    func openNote(_ id: String, jumpToAnchor anchor: (heading: String?, blockId: String?)?) {
        pendingJumpLine = nil
        pendingJumpAnchor = anchor
        select(id)
    }

    func consumeJumpLine() -> Int? {
        defer { pendingJumpLine = nil }
        return pendingJumpLine
    }

    func consumeJumpAnchor() -> (heading: String?, blockId: String?)? {
        defer { pendingJumpAnchor = nil }
        return pendingJumpAnchor
    }

    func select(_ id: VaultItem.ID?) {
        Task { await performSelect(id) }
    }

    private func performSelect(_ id: VaultItem.ID?) async {
        // Saving the note being left used to gate everything below, so a
        // click waited on a coordinated write plus a possible title-rename
        // before the new note appeared. Capture the outgoing note instead and
        // let its write run alongside the load — except when it targets the
        // very file we're about to read, which must be serialized.
        let outgoing = capturePendingWrite()
        saveTask?.cancel()
        var outgoingWrite: Task<Void, Never>?
        if let outgoing {
            if outgoing.id == id {
                await commit(outgoing, allowRename: true)
            } else {
                outgoingWrite = Task { [weak self] in
                    await self?.commit(outgoing, allowRename: true)
                }
            }
        }
        await loadSelection(id)
        // Bound the handoff: the write still finishes inside this selection,
        // it just no longer stands in front of the note appearing.
        await outgoingWrite?.value
    }

    private func loadSelection(_ id: VaultItem.ID?) async {
        selectedID = id
        if let id, !recents.contains(id) {
            // Insert-only: reordering existing entries makes the Recents
            // section shuffle under the cursor mid-click (user report).
            recents.insert(id, at: 0)
            if recents.count > 8 {
                recents.removeLast(recents.count - 8)
            }
            UserDefaults.standard.set(recents, forKey: "recentNotes")
            scheduleRecentsSettle()
        }
        if let id, !openTabs.contains(id) {
            openTabs.append(id)
        }
        guard let id, let item = notesById[id] else {
            loadedURL = nil
            noteText = ""
            if id == nil {
                rememberSelection(nil)
            }
            return
        }
        do {
            try? store.startDownloading(item.url)
            let contents = try await store.readString(at: item.url)
            loadedURL = item.url
            let document = MarkdownDocument(source: contents)
            if let envelope = LockedNoteFile.parse(
                frontmatterValues: document.frontmatter?.values ?? [:], body: document.body
            ) {
                if let key = unlockedKeys[id],
                   let plain = try? NoteCrypto.decrypt(envelope.ciphertext, key: key) {
                    noteText = plain
                    lockedPlaceholder = false
                } else {
                    noteText = ""
                    lockedPlaceholder = true
                }
            } else {
                noteText = contents
                lockedPlaceholder = false
            }
            dirty = false
            // Not if the user already moved on while this note was being read.
            if selectedID == id {
                rememberSelection(id)
            }
        } catch {
            loadedURL = nil
            noteText = ""
            lockedPlaceholder = false
        }
    }

    /// Attempts to unlock the selected locked note with a passphrase.
    func unlockSelected(passphrase: String) async -> Bool {
        guard let url = loadedURL, let id = selectedID else { return false }
        guard let contents = try? await store.readString(at: url) else { return false }
        let document = MarkdownDocument(source: contents)
        guard let envelope = LockedNoteFile.parse(
            frontmatterValues: document.frontmatter?.values ?? [:], body: document.body
        ) else { return false }
        guard let key = try? NoteCrypto.deriveKey(
            passphrase: passphrase, salt: envelope.salt, rounds: envelope.rounds
        ), let plain = try? NoteCrypto.decrypt(envelope.ciphertext, key: key)
        else { return false }
        unlockedKeys[id] = key
        noteText = plain
        lockedPlaceholder = false
        dirty = false
        return true
    }

    /// Encrypts the current note with a new passphrase and rewrites the
    /// file as ciphertext. UNRECOVERABLE if the passphrase is forgotten.
    func lockSelected(passphrase: String) async -> Bool {
        guard let url = loadedURL, let id = selectedID, !passphrase.isEmpty else { return false }
        await flushSave(allowRename: false)
        let salt = NoteCrypto.makeSalt()
        guard let key = try? NoteCrypto.deriveKey(passphrase: passphrase, salt: salt),
              let sealed = try? NoteCrypto.encrypt(noteText, key: key)
        else { return false }
        let rendered = LockedNoteFile.render(
            title: id, salt: salt, rounds: NoteCrypto.defaultRounds, ciphertext: sealed
        )
        do {
            try await store.writeString(rendered, to: url)
            unlockedKeys[id] = key
            dirty = false
            return true
        } catch {
            return false
        }
    }

    /// Decrypts back to a plain note (requires it to be unlocked already).
    func removeLockFromSelected() async {
        guard let url = loadedURL, let id = selectedID, unlockedKeys[id] != nil else { return }
        do {
            try await store.writeString(noteText, to: url)
            unlockedKeys[id] = nil
            dirty = false
        } catch {}
    }

    /// Whether the current note is a locked note (locked or unlocked state).
    var selectedIsLockable: Bool {
        selectedID.map { unlockedKeys[$0] != nil } ?? false || lockedPlaceholder
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
        guard let pending = capturePendingWrite() else { return }
        await commit(pending, allowRename: allowRename)
    }

    /// The editing state of the note being saved, captured at the moment the
    /// save starts. Selection may move on while the write is in flight, so
    /// the write cannot read `selectedID`/`noteText` when it lands.
    private struct PendingWrite {
        let id: String
        let url: URL
        let text: String
    }

    private func capturePendingWrite() -> PendingWrite? {
        guard dirty, let url = loadedURL, let id = selectedID else { return nil }
        return PendingWrite(id: id, url: url, text: noteText)
    }

    private func commit(_ pending: PendingWrite, allowRename: Bool) async {
        do {
            // Unlocked locked-notes re-encrypt on every save: plaintext
            // only ever exists in memory.
            if let key = unlockedKeys[pending.id] {
                guard let contents = try? await store.readString(at: pending.url) else { return }
                let document = MarkdownDocument(source: contents)
                guard let envelope = LockedNoteFile.parse(
                    frontmatterValues: document.frontmatter?.values ?? [:], body: document.body
                ), let sealed = try? NoteCrypto.encrypt(pending.text, key: key) else { return }
                let rendered = LockedNoteFile.render(
                    title: pending.id, salt: envelope.salt, rounds: envelope.rounds, ciphertext: sealed
                )
                try await store.writeString(rendered, to: pending.url)
                markClean(pending)
                return
            }
            try await store.writeString(pending.text, to: pending.url)
            markClean(pending)
            if allowRename {
                await renameToMatchTitle(id: pending.id, url: pending.url, text: pending.text)
            }
        } catch {
            // Keep dirty; next debounce retries. Files are truth — never
            // drop edits silently.
        }
    }

    /// Clears the dirty flag only while the written note is still the one on
    /// screen — a save that lands after the user moved on must not mark the
    /// NEW note's unsaved edits as clean.
    private func markClean(_ pending: PendingWrite) {
        if loadedURL == pending.url {
            dirty = false
        }
    }

    /// Obsidian-style title sync: when the note's first line is a heading,
    /// the file is named after it. Runs after each successful save.
    private func renameToMatchTitle(id currentId: String, url: URL, text: String) async {
        guard let root, let title = Self.headingTitle(of: text) else { return }
        let sanitized = Self.sanitizeFileName(title)
        let current = url.deletingPathExtension().lastPathComponent
        guard !sanitized.isEmpty, sanitized != current else { return }
        let folder = url.deletingLastPathComponent()
        let name = VaultNaming.uniqueFileName(base: sanitized, ext: "md", in: folder)
        let destination = folder.appendingPathComponent(name)
        do {
            try await store.move(from: url, to: destination)
            let newId = VaultPath.relativePath(of: destination, in: root)
            // Retarget the live selection ONLY when the renamed note is still
            // the one on screen. A save that completes after the user clicked
            // another note must never drag them back to the old one.
            if selectedID == currentId {
                loadedURL = destination
                selectedID = newId
                rememberSelection(newId)
            }
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
            // ATX: the `#` run needs a space or tab after it, so `#inbox #work` (a tag line) is
            // not a heading. Keep in step with `replacingFirstHeading`.
            let rest = trimmed.drop { $0 == "#" }
            guard rest.first == " " || rest.first == "\t" else { return nil }
            let title = rest.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    /// Filesystem- and sync-safe file name from a heading.
    nonisolated static func sanitizeFileName(_ title: String) -> String {
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
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try? await store.createFolder(at: attachments)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let name = VaultNaming.uniqueFileName(base: base, ext: ext, in: attachments)
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

    /// Same contract as `attachImage(from:)` above, for raw image data
    /// (a pasted screenshot, a dropped file the caller already read into
    /// memory) rather than a source `URL` — writes through a temp file so
    /// it can reuse the same coordinated `store.copy` path.
    func attachImage(data: Data, suggestedName: String) async -> String? {
        guard let root else { return nil }
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try? await store.createFolder(at: attachments)
        let ext = (suggestedName as NSString).pathExtension.isEmpty
            ? "png" : (suggestedName as NSString).pathExtension
        let base = (suggestedName as NSString).deletingPathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try data.write(to: tempURL)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let name = VaultNaming.uniqueFileName(
            base: base.isEmpty ? "image" : base, ext: ext, in: attachments
        )
        do {
            try await store.copy(from: tempURL, to: attachments.appendingPathComponent(name))
        } catch {
            return nil
        }
        let noteDepth = (selectedID ?? "").split(separator: "/").count - 1
        let up = String(repeating: "../", count: max(noteDepth, 0))
        let relative = up + "Attachments/" + name
        return relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
    }

    /// Editable in Settings; {{date}}/{{time}} expand via TemplateExpansion,
    /// {{weekday}} and {{meetings}} here.
    static let defaultDailyTemplate = """
    # {{date}}
    {{weekday}}

    {{meetings}}
    # To-Do This Week
    {{weektodos}}

    # Continuous Efforts:
    {{continuous}}

    # On the Horizon:
    {{horizon}}

    """

    /// Pre-2026-08 default, recognized so stored copies auto-upgrade.
    private static let legacyDailyTemplate = """
    # {{date}}
    {{weekday}}

    {{meetings}}
    """

    /// Wired by AppShell: index-backed planning sections.
    var dailySectionsProvider: (() -> (week: String, continuous: String, horizon: String))?

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
            let known = notes.contains { $0.relativePath == relative }
            if !known, VaultNaming.isTaken(url) {
                // Exists remotely but hasn't downloaded: pull it, never
                // overwrite it with a fresh template.
                try? store.startDownloading(url)
                apply(VaultEnumerator.snapshot(of: root))
            } else if !known {
                try? await store.createFolder(
                    at: root.appendingPathComponent("Daily", isDirectory: true)
                )
                let weekday = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                var template = UserDefaults.standard.string(forKey: "dailyNoteTemplate")
                    ?? Self.defaultDailyTemplate
                if template == Self.legacyDailyTemplate {
                    // Stored by merely opening Settings before the new
                    // sections existed — upgrade in place.
                    template = Self.defaultDailyTemplate
                }
                let meetings = CalendarService.meetingsMarkdown(
                    on: date, excludedCalendarIds: CalendarService.excludedCalendarIds()
                )
                let sections = dailySectionsProvider?()
                    ?? (week: "", continuous: "", horizon: "")
                let contents = TemplateExpansion.expand(template, title: day, now: date)
                    .replacingOccurrences(of: "{{weekday}}", with: weekday)
                    .replacingOccurrences(of: "{{meetings}}", with: meetings)
                    .replacingOccurrences(of: "{{weektodos}}", with: sections.week)
                    .replacingOccurrences(of: "{{continuous}}", with: sections.continuous)
                    .replacingOccurrences(of: "{{horizon}}", with: sections.horizon)
                try? await store.writeString(contents, to: url)
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
        let noteExtensions: Set = ["md", "markdown", "txt"]
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
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
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
            let fileName = VaultNaming.uniqueFileName(
                base: base, ext: "md", in: root,
                reserved: Set(notes.map(\.relativePath))
            )
            let title = String(fileName.dropLast(3))
            let contents = TemplateExpansion.expand(raw, title: title)
            let url = root.appendingPathComponent(fileName)
            do {
                try await store.writeString(contents, to: url)
                apply(VaultEnumerator.snapshot(of: root))
                await performSelect(title + ".md")
            } catch {
                // Surfaced implicitly: note won't appear.
            }
        }
    }

    /// Duplicates a note next to the original ("Title copy.md",
    /// overwrite-safe naming).
    func duplicate(_ item: VaultItem) {
        guard let root else { return }
        Task {
            guard let contents = try? await store.readString(at: item.url) else { return }
            let url = URL(fileURLWithPath: item.relativePath)
            let folder = url.deletingLastPathComponent().relativePath
            let base = url.deletingPathExtension().lastPathComponent + " copy"
            let folderURL = folder == "." || folder.isEmpty
                ? root : root.appendingPathComponent(folder, isDirectory: true)
            let name = VaultNaming.uniqueFileName(
                base: base, ext: "md", in: folderURL,
                reserved: Set(notes.map(\.relativePath))
            )
            let destination = folderURL.appendingPathComponent(name)
            do {
                try await store.writeString(contents, to: destination)
                apply(VaultEnumerator.snapshot(of: root))
                await performSelect(VaultPath.relativePath(of: destination, in: root))
            } catch {
                // Surfaced implicitly: the copy won't appear.
            }
        }
    }

    func createNote(in folder: String = "") {
        createNote(titled: "Untitled", in: folder)
    }

    /// A new note named after `title` (sanitised, uniquified) with a matching H1, opened. The
    /// unresolved-wikilink "Create Note" path (spec ux-phase2/06) passes the link's title.
    func createNote(titled title: String, in folder: String = "") {
        guard let root else { return }
        let base = Self.sanitizeFileName(title).isEmpty ? "Untitled" : Self.sanitizeFileName(title)
        // `[[_index]]` must not mint the app-generated folder index; same toast as a rename.
        guard !Self.isReservedName(base) else {
            renameFailure = Self.message(for: .invalidName, base: base)
            return
        }
        Task {
            let prefix = folder.isEmpty ? "" : folder + "/"
            let reserved = Set(
                notes.map(\.relativePath)
                    .filter { $0.hasPrefix(prefix) }
                    .map { String($0.dropFirst(prefix.count)) }
            )
            let name = prefix + VaultNaming.uniqueFileName(
                base: base, ext: "md",
                in: root.appendingPathComponent(folder, isDirectory: true),
                reserved: reserved
            )
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
                let destination = root.appendingPathComponent(newRelative)
                try await store.move(from: item.url, to: destination)
                // The note's id IS its path, so everything keyed by it follows the move. Missing
                // the unlock key made the next save of an unlocked locked note write plaintext;
                // missing `loadedURL` made typing recreate the note at its OLD path.
                unlockedKeys.rekey(from: item.id, to: newRelative)
                if loadedURL == item.url {
                    loadedURL = destination
                }
                if let index = openTabs.firstIndex(of: item.id) {
                    openTabs[index] = newRelative
                }
                if selectedID == item.id {
                    selectedID = newRelative
                    rememberSelection(newRelative)
                }
                if recents.contains(item.id) {
                    recents = recents.map { $0 == item.id ? newRelative : $0 }
                    UserDefaults.standard.set(recents, forKey: "recentNotes")
                }
                apply(VaultEnumerator.snapshot(of: root))
            } catch {
                // Move failed; list refresh will show reality.
            }
        }
    }

    // MARK: - Rename (spec ux-phase2/05)

    struct RenameReceipt: Equatable {
        let oldId: String
        let newId: String
        let oldTitle: String
        let newTitle: String
        /// The first heading's text before the rename (nil when the note had none or its body
        /// was not readable, i.e. locked). Undo writes it back, so a heading that differed from
        /// the file name ("Plan: Q3" in "Plan- Q3.md") comes back byte for byte.
        let oldHeading: String?
    }

    enum RenameError: Error, Equatable {
        case invalidName
        case nameTaken
        case hasConflicts
        case saveFailed
        /// The note was renamed or removed while its pending text was being saved.
        case noteChanged
        case moveFailed(String)
    }

    /// The most recent rename, for the Undo toast (6 s, same pattern as `lastTrashed`).
    private(set) var lastRenamed: RenameReceipt?
    /// Why an Undo Rename (or a rename's follow-up) failed, for a transient message.
    private(set) var renameFailure: String?

    /// File name a requested title is saved under: `sanitizeFileName` plus the characters that
    /// would make `[[New]]` parse differently from the name (`#` starts a heading, `[` `]`
    /// end the link) become "-", and line breaks become spaces. Title-sync's own sanitising is
    /// deliberately left alone, so existing notes are not renamed by this.
    nonisolated static func renameBaseName(_ requested: String) -> String {
        let cleaned = String(requested.map { character -> Character in
            if character.isNewline {
                return " "
            }
            return "#[]".contains(character) ? "-" : character
        })
        return sanitizeFileName(cleaned)
    }

    /// Why `requested` can't be used as `item`'s new name, nil when it can (also nil when it
    /// is the current name: nothing to do, not an error). Shared by the sheet's live
    /// validation and `rename` itself.
    func renameProblem(_ item: VaultItem, to requested: String) -> RenameError? {
        renameProblem(item, toBase: Self.renameBaseName(requested))
    }

    /// `_index.md` is app-generated per folder; a note by that name (any case, on a
    /// case-insensitive volume) would vanish from the list and be overwritten.
    nonisolated static func isReservedName(_ base: String) -> Bool {
        base.lowercased() == "_index"
    }

    /// `renameProblem(_:to:)` for a file base that is already clean (Undo passes the old file
    /// name as it was, which may hold a `#` that a typed name would lose).
    private func renameProblem(_ item: VaultItem, toBase newBase: String) -> RenameError? {
        guard !newBase.isEmpty, !Self.isReservedName(newBase) else { return .invalidName }
        let oldBase = Self.noteTitle(ofPath: item.id)
        guard newBase != oldBase else { return nil }
        let folder = item.url.deletingLastPathComponent()
        if newBase.lowercased() == oldBase.lowercased() {
            // Case-only: the volume says the destination exists (it is this very file) when it
            // is case-insensitive. Only a second, distinct file of exactly that name counts.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.contains(newBase + ".md") ? .nameTaken : nil
        }
        if VaultNaming.isTaken(folder.appendingPathComponent(newBase + ".md")) {
            return .nameTaken
        }
        // The listing can know a note the disk check misses (case-sensitive volume, links
        // resolve case-insensitively, so "plan" next to "Plan" would be ambiguous).
        let prefix = item.id.contains("/") ? (item.id as NSString).deletingLastPathComponent + "/" : ""
        let wanted = prefix + newBase + ".md"
        let clash = notes.contains {
            $0.id != item.id && $0.id.compare(wanted, options: .caseInsensitive) == .orderedSame
        }
        return clash ? .nameTaken : nil
    }

    /// Renames a note (spec 05 §Algorithm). Order matters for crash/failure safety:
    /// 1 validate → 2 flush the editor → 3 set the heading under the OLD path → 4 coordinated
    /// move → 5 retarget everything keyed by the id (incl. the unlock key) → 6 rewrite the
    /// note's own links → 7 relist. Each step's failure stops the sequence and is returned;
    /// earlier steps are not rolled back (a heading that already says New is completed by the
    /// note's next save, through title-sync). Inbound links are the caller's step 8
    /// (`VaultIndexService.rewriteInboundLinks`), then `rescan()`.
    func rename(_ item: VaultItem, to requestedTitle: String) async -> Result<RenameReceipt, RenameError> {
        let result = await performRename(item, toBase: Self.renameBaseName(requestedTitle), heading: nil)
        if case let .success(receipt) = result, receipt.oldId != receipt.newId {
            lastRenamed = receipt
        }
        return result
    }

    /// Undo for the toast: the reverse rename through the same path (same checks, so it
    /// refuses if the old name was taken meanwhile). Returns the reverse receipt so the caller
    /// can run the inbound rewrite New → Old; nil (with `renameFailure` set) when it failed.
    func undoLastRename() async -> RenameReceipt? {
        guard let receipt = lastRenamed else { return nil }
        lastRenamed = nil
        guard let item = notesById[receipt.newId] else {
            renameFailure = "Couldn't undo the rename: “\(receipt.newTitle)” is no longer in the vault."
            return nil
        }
        switch await performRename(item, toBase: receipt.oldTitle, heading: receipt.oldHeading) {
        case let .success(reverse):
            renameFailure = nil
            return reverse.oldId == reverse.newId ? nil : reverse
        case let .failure(error):
            renameFailure = "Couldn't undo the rename: \(Self.message(for: error, base: receipt.oldTitle))"
            return nil
        }
    }

    /// The toast timed out, Undo ran, or a failure message expired.
    func dismissRenameNotice() {
        lastRenamed = nil
        renameFailure = nil
    }

    /// `base`: the cleaned file name the rename was asked for.
    nonisolated static func message(for error: RenameError, base: String) -> String {
        switch error {
        case .invalidName: base.isEmpty ? "Name can't be empty." : "“\(base)” is reserved for the app's folder index."
        case .nameTaken: "“\(base)” already exists in this folder."
        case .hasConflicts: "This note has an unresolved sync conflict. Resolve it first."
        case .saveFailed: "Couldn't save the note before renaming it."
        case .noteChanged: "The note changed while it was being saved. Try again."
        case let .moveFailed(reason): "Couldn't rename: \(reason)"
        }
    }

    /// `heading`: the text to put in the first heading (Undo's original); nil = the new name.
    private func performRename(
        _ item: VaultItem, toBase newBase: String, heading: String?
    ) async -> Result<RenameReceipt, RenameError> {
        guard let root else { return .failure(.moveFailed("the vault isn't ready")) }
        // 1. Validate. Nothing has been written yet.
        if let problem = renameProblem(item, toBase: newBase) {
            return .failure(problem)
        }
        let oldBase = Self.noteTitle(ofPath: item.id)
        guard newBase != oldBase else {
            return .success(RenameReceipt(
                oldId: item.id, newId: item.id, oldTitle: oldBase, newTitle: newBase, oldHeading: nil
            ))
        }
        let caseOnly = newBase.lowercased() == oldBase.lowercased()
        if item.hasUnresolvedConflicts || !VaultConflictCenter().unresolvedVersions(for: item.url).isEmpty {
            return .failure(.hasConflicts)
        }
        // Resolution pool as it is BEFORE the rename: self links resolve against it.
        let pool = notes.map { (id: $0.id, title: Self.noteTitle(ofPath: $0.id)) }

        // 2. Flush the editor under the current name. An autosave already past its debounce
        // finishes first (it may title-sync), then whatever is still pending is written with
        // title-sync OFF, so nothing moves the file under the steps below.
        saveTask?.cancel()
        await saveTask?.value
        await flushSave(allowRename: false)
        let isOpen = selectedID == item.id
        if isOpen, dirty {
            return .failure(.saveFailed)
        }
        // Re-resolve: if the file moved or vanished meanwhile, stop rather than guess.
        apply(VaultEnumerator.snapshot(of: root))
        guard let current = notesById[item.id], !isOpen || loadedURL == current.url else {
            return .failure(.noteChanged)
        }

        // 3. Heading sync under the OLD path, so a crash or a failed move below leaves a note
        // whose next save (title-sync) completes the rename instead of reverting it.
        let headingText = heading ?? newBase
        var oldHeading: String?
        if isOpen, !lockedPlaceholder {
            // The editor's text: plaintext for an unlocked locked note too, and the save below
            // re-encrypts it (`commit` checks the unlock key first).
            if let synced = Self.replacingFirstHeading(in: noteText, with: headingText) {
                oldHeading = synced.previous
                noteText = synced.text
                dirty = true
                await flushSave(allowRename: false)
                if dirty {
                    return .failure(.saveFailed)
                }
            }
        } else {
            do {
                let contents = try await store.readString(at: current.url)
                // A locked file's body is ciphertext: no heading to sync, nothing to write.
                if MarkdownDocument(source: contents).frontmatter?.values["locked"] != "true",
                   let synced = Self.replacingFirstHeading(in: contents, with: headingText) {
                    oldHeading = synced.previous
                    try await store.writeString(synced.text, to: current.url)
                }
            } catch {
                return .failure(.saveFailed)
            }
        }

        // 4. Move (coordinated, never overwrites). A case-only rename that the volume refuses
        // goes through a temporary name in the same folder.
        let folder = current.url.deletingLastPathComponent()
        let destination = folder.appendingPathComponent(newBase + ".md")
        let tabIndex = openTabs.firstIndex(of: item.id)
        do {
            do {
                try await store.move(from: current.url, to: destination)
            } catch where caseOnly {
                let temporary = folder.appendingPathComponent("\(oldBase).md.renaming-\(UUID().uuidString)")
                try await store.move(from: current.url, to: temporary)
                do {
                    try await store.move(from: temporary, to: destination)
                } catch {
                    try? await store.move(from: temporary, to: current.url)
                    throw error
                }
            }
        } catch {
            return .failure(.moveFailed(error.localizedDescription))
        }

        // 5. Retarget everything keyed by the id (the id IS the path). Same calls as
        // `move(toFolder:)`: a missed unlock key makes the next save of an unlocked locked note
        // write PLAINTEXT; a missed `loadedURL` makes typing recreate the old file.
        let newId = VaultPath.relativePath(of: destination, in: root)
        let oldId = item.id
        unlockedKeys.rekey(from: oldId, to: newId)
        if loadedURL == current.url {
            loadedURL = destination
        }
        if let index = openTabs.firstIndex(of: oldId) {
            openTabs[index] = newId
        } else if let tabIndex, !openTabs.contains(newId) {
            // A listing refresh during the move already dropped the old id.
            openTabs.insert(newId, at: min(tabIndex, openTabs.count))
        }
        if selectedID == oldId {
            selectedID = newId
            rememberSelection(newId)
        }
        if recents.contains(oldId) {
            recents = recents.map { $0 == oldId ? newId : $0 }
            UserDefaults.standard.set(recents, forKey: "recentNotes")
        }
        displayedRecents = displayedRecents.map { $0 == oldId ? newId : $0 }
        if sidebar.listSelection == oldId {
            sidebar.listSelection = newId
        }
        if let highlight = sidebar.sectionHighlight, highlight.hasSuffix("|" + oldId) {
            sidebar.sectionHighlight = String(highlight.dropLast(oldId.count)) + newId
        }

        // 6. The note's own links to itself. Failure here does not undo the rename.
        await rewriteSelfLinks(
            id: newId, url: destination, sourceId: oldId, old: oldBase, new: newBase, pool: pool
        )

        // 7. Relist.
        apply(VaultEnumerator.snapshot(of: root))
        return .success(RenameReceipt(
            oldId: oldId, newId: newId, oldTitle: oldBase, newTitle: newBase, oldHeading: oldHeading
        ))
    }

    /// Step 6: `[[Old]]` inside the renamed note itself. The open note goes through the
    /// editor text (re-encrypted on save when it is an unlocked locked note); a closed locked
    /// note is left alone (ciphertext).
    private func rewriteSelfLinks(
        id: String, url: URL, sourceId: String, old: String, new: String,
        pool: [(id: String, title: String)]
    ) async {
        if selectedID == id, loadedURL == url, !lockedPlaceholder {
            let result = WikilinkRenameRewrite.rewrite(
                noteText, sourceId: sourceId, renamingTitle: old, to: new, renamedId: sourceId, among: pool
            )
            guard result.count > 0 else { return }
            noteText = result.text
            dirty = true
            await flushSave(allowRename: false)
            if dirty {
                renameFailure = "Renamed, but couldn't update the links inside “\(new)” itself."
            }
            return
        }
        guard let contents = try? await store.readString(at: url) else { return }
        guard MarkdownDocument(source: contents).frontmatter?.values["locked"] != "true" else { return }
        let result = WikilinkRenameRewrite.rewrite(
            contents, sourceId: sourceId, renamingTitle: old, to: new, renamedId: sourceId, among: pool
        )
        guard result.count > 0 else { return }
        do {
            try await store.writeString(result.text, to: url)
        } catch {
            renameFailure = "Renamed, but couldn't update the links inside “\(new)” itself."
        }
    }

    /// Replaces the TEXT of the first heading (the line `headingTitle(of:)` reads) with
    /// `title`, keeping its `#` run, the spacing around the text and a trailing `\r`. Nil when
    /// the first non-empty body line is not a heading. `previous` is the text it replaced.
    nonisolated static func replacingFirstHeading(
        in text: String, with title: String
    ) -> (text: String, previous: String)? {
        let document = MarkdownDocument(source: text)
        let ns = text as NSString
        var lineStart = document.bodyUTF16Offset
        let newline = unichar(0x0A)
        while lineStart <= ns.length {
            var lineEnd = lineStart
            while lineEnd < ns.length, ns.character(at: lineEnd) != newline {
                lineEnd += 1
            }
            let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let content = strippingCarriageReturn(line)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                guard trimmed.hasPrefix("#") else { return nil }
                // Locate the title inside the line: after leading spaces, the # run and the
                // spaces that follow it; before trailing spaces.
                let chars = content as NSString
                var start = 0
                while start < chars.length, isSpace(chars.character(at: start)) {
                    start += 1
                }
                while start < chars.length, chars.character(at: start) == 0x23 {
                    start += 1
                }
                // Same rule as `headingTitle(of:)`: no space after the `#` run, no heading.
                guard start < chars.length, isSpace(chars.character(at: start)) else { return nil }
                while start < chars.length, isSpace(chars.character(at: start)) {
                    start += 1
                }
                var end = chars.length
                while end > start, isSpace(chars.character(at: end - 1)) {
                    end -= 1
                }
                guard end > start else { return nil }
                let range = NSRange(location: start, length: end - start)
                let previous = chars.substring(with: range)
                let replaced = ns.replacingCharacters(
                    in: NSRange(location: lineStart + start, length: range.length), with: title
                )
                return (replaced, previous)
            }
            lineStart = lineEnd + 1
        }
        return nil
    }

    private nonisolated static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    // MARK: - Trash

    /// Moves a note into the vault's hidden `.trash/` folder (never a permanent delete).
    /// Opening the note first flushes its pending keystrokes so the trashed file holds the
    /// latest text. Sets `lastTrashed` for the Undo toast; `trashFailure` when the move fails.
    func moveToTrash(_ item: VaultItem) async {
        guard let root else { return }
        if selectedID == item.id || loadedURL == item.url {
            // Write the pending text under the CURRENT name: a title-sync rename here would
            // move the file out from under the trash move below. Then drop the selection
            // (that also unloads the editor, so nothing can save into the old path later).
            await flushSave(allowRename: false)
            await performSelect(nil)
        }
        // Re-resolve after the flush; if the file was renamed or removed meanwhile, do nothing
        // rather than guess which note was meant.
        guard let current = notesById[item.id] else {
            trashFailure = "Couldn't move “\(Self.noteTitle(ofPath: item.id))” to Trash: it changed while it was being saved."
            return
        }
        do {
            let receipt = try await VaultTrash.trash(relativePath: current.relativePath, in: root, store: store)
            // A locked note that was unlocked this session locks again (and stays locked on restore).
            unlockedKeys[item.id] = nil
            apply(VaultEnumerator.snapshot(of: root))
            trashFailure = nil
            lastTrashed = receipt
        } catch {
            trashFailure = "Couldn't move “\(Self.noteTitle(ofPath: item.id))” to Trash: \(error.localizedDescription)"
        }
    }

    /// Undo for the toast: moves the most recent trashed note back to where it was and opens it.
    func undoLastTrash() async {
        guard let receipt = lastTrashed, let root else { return }
        lastTrashed = nil
        do {
            let restored = try await VaultTrash.restore(receipt.entry, in: root, store: store)
            apply(VaultEnumerator.snapshot(of: root))
            await performSelect(restored)
        } catch {
            trashFailure = "Couldn't restore “\(Self.noteTitle(ofPath: receipt.originalPath))”: \(error.localizedDescription)"
        }
    }

    /// The toast timed out (or was replaced): the note stays in the Trash, restorable from the sheet.
    func dismissTrashNotice() {
        lastTrashed = nil
        trashFailure = nil
    }

    /// "Folder/Plan.md" → "Plan", for messages.
    nonisolated static func noteTitle(ofPath path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// Live listing of `.trash/`, newest first. Read off the main actor: it walks the folder.
    func trashEntries() async -> [VaultTrash.Entry] {
        guard let root else { return [] }
        return await Task.detached(priority: .userInitiated) { VaultTrash.list(in: root) }.value
    }

    /// Moves a trashed note back (uniquified if its name is taken). Returns the restored path.
    @discardableResult
    func restore(_ entry: VaultTrash.Entry) async throws -> String {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        defer { apply(VaultEnumerator.snapshot(of: root)) }
        return try await VaultTrash.restore(entry, in: root, store: store)
    }

    /// Permanently deletes one trashed note.
    func purge(_ entry: VaultTrash.Entry) async throws {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        try await VaultTrash.purge(entry, in: root, store: store)
    }

    /// Permanently deletes everything in the Trash.
    func emptyTrash() async throws {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        try await VaultTrash.empty(in: root, store: store)
    }
}

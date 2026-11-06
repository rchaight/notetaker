import Foundation

public enum VaultTrashError: Error, Equatable, LocalizedError {
    /// Empty, absolute, `.`/`..`, or otherwise not a plain relative vault path.
    case invalidPath(String)
    /// The note is already inside the Trash folder.
    case alreadyInTrash(String)
    /// Folders are not trashed (only notes).
    case notAFile(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): "“\(path)” is not a valid vault path."
        case let .alreadyInTrash(path): "“\(path)” is already in the Trash."
        case let .notAFile(path): "“\(path)” is a folder; only notes can be moved to the Trash."
        }
    }
}

/// The vault's Trash: a hidden `<vault>/.trash/` folder that every reader of the vault
/// already ignores (enumerator, metadata observer, `ReplicaExporter`, `ExportPolicy`, MCP scan).
///
/// There is no state outside the vault. Trashing is a coordinated MOVE into `.trash/` that
/// keeps the note's relative path (`Work/Plan.md` → `.trash/Work/Plan.md`), restoring is the
/// move back, and `list` is a live listing of the folder — so Undo is a move, never a cached
/// copy, and the Trash syncs through iCloud like any other folder.
public enum VaultTrash {
    /// Obsidian's convention; hidden everywhere.
    public static let folderName = ".trash"

    /// What `trash` did, enough to undo it.
    public struct Receipt: Sendable, Equatable {
        public let originalPath: String
        public let trashedPath: String

        public init(originalPath: String, trashedPath: String) {
            self.originalPath = originalPath
            self.trashedPath = trashedPath
        }

        /// The Trash entry this receipt points at, for `restore`.
        public var entry: Entry {
            Entry(trashedPath: trashedPath, originalPath: originalPath, modificationDate: nil)
        }
    }

    public struct Entry: Sendable, Identifiable, Equatable {
        public var id: String {
            trashedPath
        }

        /// Relative to the vault root; starts with ".trash/".
        public let trashedPath: String
        /// `trashedPath` with the ".trash/" prefix removed.
        public let originalPath: String
        /// The note's own modification date (a move does not change it).
        public let modificationDate: Date?

        public init(trashedPath: String, originalPath: String, modificationDate: Date?) {
            self.trashedPath = trashedPath
            self.originalPath = originalPath
            self.modificationDate = modificationDate
        }

        public init(trashedPath: String, modificationDate: Date?) {
            let prefix = VaultTrash.folderName + "/"
            self.init(
                trashedPath: trashedPath,
                originalPath: trashedPath.hasPrefix(prefix) ? String(trashedPath.dropFirst(prefix.count)) : trashedPath,
                modificationDate: modificationDate
            )
        }
    }

    // MARK: - Operations

    /// Coordinated move of `root/relativePath` → `root/.trash/<same relative path>`,
    /// uniquified (`Note 2.md`) when the trash already holds that name.
    public static func trash(relativePath: String, in root: URL, store: VaultFileStore) async throws -> Receipt {
        guard let parts = plainComponents(of: relativePath) else {
            throw VaultTrashError.invalidPath(relativePath)
        }
        guard parts[0].lowercased() != folderName else {
            throw VaultTrashError.alreadyInTrash(relativePath)
        }
        let source = root.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw VaultTrashError.notAFile(relativePath)
        }

        let folders = Array(parts.dropLast())
        let trashFolder = folderURL(root: root, components: [folderName] + folders)
        let name = uniqueName(for: parts[parts.count - 1], in: trashFolder)
        try await store.move(from: source, to: trashFolder.appendingPathComponent(name))
        return Receipt(
            originalPath: relativePath,
            trashedPath: ([folderName] + folders + [name]).joined(separator: "/")
        )
    }

    /// Coordinated move back to `entry.originalPath` (uniquified when that name is taken
    /// again). Removes the empty `.trash` subfolders it leaves behind. Returns the restored
    /// relative path.
    public static func restore(_ entry: Entry, in root: URL, store: VaultFileStore) async throws -> String {
        let trashed = try trashedComponents(of: entry)
        guard let original = plainComponents(of: entry.originalPath) else {
            throw VaultTrashError.invalidPath(entry.originalPath)
        }
        let folders = Array(original.dropLast())
        let destinationFolder = folderURL(root: root, components: folders)
        let name = uniqueName(for: original[original.count - 1], in: destinationFolder)
        try await store.move(
            from: root.appendingPathComponent(entry.trashedPath),
            to: destinationFolder.appendingPathComponent(name)
        )
        await pruneEmptyFolders(of: trashed, in: root, store: store)
        return (folders + [name]).joined(separator: "/")
    }

    /// Permanent delete of that one entry (and any empty subfolders it leaves).
    public static func purge(_ entry: Entry, in root: URL, store: VaultFileStore) async throws {
        let trashed = try trashedComponents(of: entry)
        try await store.delete(at: root.appendingPathComponent(entry.trashedPath))
        await pruneEmptyFolders(of: trashed, in: root, store: store)
    }

    /// Permanently deletes everything inside `.trash` (the folder itself stays). Keeps going
    /// past a failed item and rethrows the first error at the end.
    public static func empty(in root: URL, store: VaultFileStore) async throws {
        let trashRoot = folderURL(root: root, components: [folderName])
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashRoot.path) else { return }
        var firstError: Error?
        for name in names {
            do {
                try await store.delete(at: trashRoot.appendingPathComponent(name))
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// Enumerates `root/.trash` directly (so `.skipsHiddenFiles` cannot hide the contents),
    /// `.md` notes only, newest first. An undownloaded iCloud placeholder (`.Note.md.icloud`)
    /// is listed under its real name.
    public static func list(in root: URL) -> [Entry] {
        var entries: [Entry] = []
        collect(
            folder: folderURL(root: root, components: [folderName]),
            relative: [folderName],
            into: &entries
        )
        return entries.sorted {
            let lhs = $0.modificationDate ?? .distantPast
            let rhs = $1.modificationDate ?? .distantPast
            return lhs == rhs ? $0.trashedPath < $1.trashedPath : lhs > rhs
        }
    }

    // MARK: - Plumbing

    private static func collect(folder: URL, relative: [String], into entries: inout [Entry]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if !name.hasPrefix(".") {
                    collect(folder: url, relative: relative + [name], into: &entries)
                }
                continue
            }
            let realName: String
            if let placeholder = placeholderName(name) {
                realName = placeholder
            } else if name.hasPrefix(".") {
                continue
            } else {
                realName = name
            }
            guard realName.lowercased().hasSuffix(".md") else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            entries.append(Entry(
                trashedPath: (relative + [realName]).joined(separator: "/"),
                modificationDate: modified
            ))
        }
    }

    /// ".Note.md.icloud" → "Note.md"; nil for any other name.
    private static func placeholderName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return real.isEmpty ? nil : real
    }

    /// Path components of a plain relative path, nil when empty, absolute, containing an
    /// empty/"."/".." component or a NUL. Trash operations never leave the vault.
    private static func plainComponents(of relativePath: String) -> [String]? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !relativePath.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        return parts
    }

    /// Components of `entry.trashedPath`, requiring it to sit strictly inside `.trash/` —
    /// `purge` and `restore` can never be pointed at a path outside the Trash.
    private static func trashedComponents(of entry: Entry) throws -> [String] {
        guard let parts = plainComponents(of: entry.trashedPath), parts.count >= 2,
              parts[0].lowercased() == folderName
        else {
            throw VaultTrashError.invalidPath(entry.trashedPath)
        }
        return parts
    }

    private static func folderURL(root: URL, components: [String]) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// `fileName` itself when free in `folder`, else "Base 2.ext", "Base 3.ext"…
    private static func uniqueName(for fileName: String, in folder: URL) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        if !ext.isEmpty {
            return VaultNaming.uniqueFileName(base: base, ext: ext, in: folder)
        }
        var name = fileName
        var counter = 2
        while VaultNaming.isTaken(folder.appendingPathComponent(name)) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    /// Removes the now-empty subfolders between a trashed file and `.trash` itself (never
    /// `.trash`). A folder holding only Finder's `.DS_Store` counts as empty. Best effort.
    private static func pruneEmptyFolders(of trashed: [String], in root: URL, store: VaultFileStore) async {
        var folders = Array(trashed.dropLast())
        while folders.count > 1 {
            let url = folderURL(root: root, components: folders)
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                  contents.allSatisfy({ $0 == ".DS_Store" })
            else { return }
            do {
                try await store.delete(at: url)
            } catch {
                return
            }
            folders.removeLast()
        }
    }
}

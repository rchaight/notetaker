import Foundation
import MarkdownKit

/// One markdown file in the vault, as the filesystem sees it.
struct VaultFile: Sendable, Equatable {
    /// Vault-relative path — the same id IndexKit uses for `note.id`.
    let relativePath: String
    let url: URL
    let modifiedAt: Date?

    var title: String {
        (relativePath as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    var folder: String {
        relativePath.split(separator: "/").dropLast().joined(separator: "/")
    }
}

/// Direct filesystem access to the vault. This is the fallback path that
/// makes the index an accelerator rather than a requirement — and the only
/// path for note bodies, which never live in the DB.
enum VaultFiles {
    /// Folder table-of-contents files spec 01 writes; they are machinery,
    /// not notes, so they never appear as search results or task sources.
    static let indexFileName = "_index.md"

    /// Every note under `root`, sorted by path. Tolerant of files vanishing
    /// mid-scan — iCloud and Obsidian may be writing at any moment.
    static func markdownFiles(in root: URL, includingIndexFiles: Bool = false) -> [VaultFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [VaultFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let name = url.lastPathComponent
            if !includingIndexFiles, name == indexFileName {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                continue
            }
            files.append(VaultFile(
                relativePath: relativePath(of: url, in: root),
                url: url,
                modifiedAt: values?.contentModificationDate
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// Immediate subfolder names of `folder`, vault-relative.
    static func subfolders(of folder: URL, in root: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { relativePath(of: $0, in: root) }
            .sorted()
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Resolves a caller-supplied path against the root, refusing anything
    /// that escapes the vault. Read-only server or not, `../../.ssh` is not
    /// a note.
    static func resolve(relativePath path: String, in root: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw VaultReadError.outsideVault(path)
        }
        return url
    }

    /// Best-effort uncoordinated read, for bulk work (search scoring,
    /// snippets) where a missing file just means one fewer result.
    static func quickRead(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

enum VaultReadError: Error, CustomStringConvertible {
    case notFound(String)
    case outsideVault(String)
    case notDownloaded(String)

    var description: String {
        switch self {
        case let .notFound(path):
            "no note at \(path)"
        case let .outsideVault(path):
            "\(path) is outside the vault"
        case let .notDownloaded(path):
            "\(path) is in iCloud but not downloaded locally — open it in Notetaker first"
        }
    }
}

/// A note as the server hands it out. `body` is nil for locked notes: their
/// on-disk content is ciphertext and must never leave the vault.
struct VaultNote: Sendable {
    let relativePath: String
    let title: String
    let locked: Bool
    let frontmatter: [String: String]
    let body: String?
}

enum NoteReader {
    /// Coordinated read of one note, downloading an iCloud placeholder first
    /// if that's what's on disk.
    static func read(relativePath path: String, in root: URL,
                     downloadTimeout: Duration = .seconds(5)) async throws -> VaultNote {
        var url = try VaultFiles.resolve(relativePath: path, in: root)
        if url.pathExtension.lowercased() != "md" {
            url.appendPathExtension("md")
        }
        try await ensureDownloaded(url, relativePath: path, timeout: downloadTimeout)
        let contents = try await coordinatedRead(url)
        return note(from: contents, relativePath: VaultFiles.relativePath(of: url, in: root))
    }

    static func note(from contents: String, relativePath: String) -> VaultNote {
        let document = MarkdownDocument(source: contents)
        let values = document.frontmatter?.values ?? [:]
        let locked = values["locked"] == "true"
        return VaultNote(
            relativePath: relativePath,
            title: (relativePath as NSString).lastPathComponent
                .replacingOccurrences(of: ".md", with: ""),
            locked: locked,
            frontmatter: values,
            body: locked ? nil : document.body
        )
    }

    /// iCloud stores an undownloaded file as `.Name.md.icloud`. Ask the
    /// daemon for it and poll — the alternative is handing Claude an error
    /// for a note that exists.
    private static func ensureDownloaded(_ url: URL, relativePath: String, timeout: Duration) async throws {
        if isReadable(url) {
            return
        }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard FileManager.default.fileExists(atPath: placeholder.path) else {
            throw VaultReadError.notFound(relativePath)
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            if isReadable(url) {
                return
            }
        }
        throw VaultReadError.notDownloaded(relativePath)
    }

    private static func isReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        // Non-ubiquitous files report no status at all, which is fine.
        return status == nil || status == .current
    }

    /// NSFileCoordinator so we never read a half-written file out from under
    /// the app or the iCloud daemon.
    private static func coordinatedRead(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<String, any Error>?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { actualURL in
                result = Result { try String(contentsOf: actualURL, encoding: .utf8) }
            }
            if let coordinationError {
                throw coordinationError
            }
            guard let result else { throw VaultReadError.notFound(url.lastPathComponent) }
            return try result.get()
        }.value
    }
}

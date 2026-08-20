import AIKit
import Foundation
import IndexKit
import MCP

/// Everything the MCP tools actually do. Kept free of the MCP `Server` so
/// `swift test` can drive it directly.
///
/// Concurrency: an immutable `Sendable` value. `IndexDatabase` wraps a GRDB
/// `DatabaseQueue`, which serialises its own access, so tool calls can run
/// concurrently without an actor in front of them. Nothing here mutates
/// shared state — the server is read-only by construction, not by policy.
public struct VaultService: Sendable {
    let location: VaultLocation
    let index: IndexDatabase?
    /// Why the index isn't in play, for the `index_status` field.
    let indexStatus: String
    let embeddings: any EmbeddingProvider

    public init(
        location: VaultLocation,
        embeddings: any EmbeddingProvider = AppleEmbeddingProvider()
    ) {
        self.location = location
        self.embeddings = embeddings
        guard let path = location.indexPath else {
            index = nil
            indexStatus = "no index for this vault — answering from the files"
            return
        }
        do {
            index = try IndexDatabase.openReadOnly(path: path)
            indexStatus = "ok"
        } catch {
            index = nil
            indexStatus = "unavailable (\(error)) — answering from the files"
        }
    }

    /// Runs an index query, returning nil if the index is absent or the
    /// query fails (busy, corrupt, schema drift). Callers then scan.
    func withIndex<T>(_ body: (IndexDatabase) throws -> T) -> T? {
        guard let index else { return nil }
        return try? body(index)
    }

    // MARK: - vault_overview

    public func vaultOverview() -> Value {
        let files = VaultFiles.markdownFiles(in: location.root)
        let indexed = withIndex { try $0.allNotes() }
        var payload: [String: Value] = [
            "source": .string(indexed == nil ? "scan" : "index"),
            "vault_root": .string(location.root.path),
            "vault_origin": .string(location.origin.rawValue),
            "index_status": .string(indexStatus),
            "note_count": .int(indexed?.count ?? files.count),
        ]

        if let claudeFile = VaultFiles.quickRead(location.root.appendingPathComponent("CLAUDE.md")) {
            payload["claude_md"] = .string(claudeFile)
        }
        if let rootIndex = VaultFiles.quickRead(
            location.root.appendingPathComponent(VaultFiles.indexFileName)
        ) {
            payload["index_md"] = .string(rootIndex)
        } else {
            payload["tree"] = .array(folderTree(files: files))
            payload["tree_note"] = .string(
                "No _index.md at the vault root yet — this tree was computed from the files."
            )
        }

        let recent = files
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .prefix(15)
            .map { file in
                Value.object([
                    "path": .string(file.relativePath),
                    "title": .string(file.title),
                    "modified": file.modifiedAt.map { .string(Self.day.string(from: $0)) } ?? .null,
                ])
            }
        payload["recently_modified"] = .array(recent)
        return .object(payload)
    }

    private func folderTree(files: [VaultFile]) -> [Value] {
        var counts: [String: Int] = [:]
        for file in files {
            counts[file.folder.isEmpty ? "/" : file.folder, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { folder, count in
            .object(["path": .string(folder), "notes": .int(count)])
        }
    }

    // MARK: - list_folder

    public func listFolder(path: String) throws -> Value {
        let folder = try VaultFiles.resolve(relativePath: path, in: location.root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw VaultReadError.notFound(path) }

        let files = VaultFiles.markdownFiles(in: folder)
            .filter { !$0.relativePath.contains("/") } // this folder only
        var payload: [String: Value] = [
            "source": .string("scan"),
            "path": .string(VaultFiles.relativePath(of: folder, in: location.root)),
            "folders": .array(VaultFiles.subfolders(of: folder, in: location.root).map { .string($0) }),
        ]

        let entries = files.map { file -> Value in
            let locked = isLocked(file.url)
            return .object([
                "path": .string(VaultFiles.relativePath(of: file.url, in: location.root)),
                "title": .string(file.title),
                "locked": .bool(locked),
                "modified": file.modifiedAt.map { .string(Self.day.string(from: $0)) } ?? .null,
            ])
        }
        payload["notes"] = .array(entries)

        if let listing = VaultFiles.quickRead(folder.appendingPathComponent(VaultFiles.indexFileName)) {
            payload["index_md"] = .string(listing)
        } else {
            payload["listing"] = .string(markdownListing(for: folder, entries: files))
        }
        return .object(payload)
    }

    /// The computed stand-in for a folder's `_index.md`, in the same shape:
    /// a heading and one bullet per note, locked ones flagged.
    private func markdownListing(for folder: URL, entries: [VaultFile]) -> String {
        let name = VaultFiles.relativePath(of: folder, in: location.root)
        var lines = ["# \(name.isEmpty ? "Vault" : name)", ""]
        for subfolder in VaultFiles.subfolders(of: folder, in: location.root) {
            lines.append("- 📁 \(subfolder)")
        }
        for file in entries {
            let path = VaultFiles.relativePath(of: file.url, in: location.root)
            lines.append("- [\(file.title)](\(path))\(isLocked(file.url) ? " 🔒" : "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - read_note

    public func readNote(path: String) async throws -> Value {
        let note = try await NoteReader.read(relativePath: path, in: location.root)
        var payload: [String: Value] = [
            "path": .string(note.relativePath),
            "title": .string(note.title),
            "locked": .bool(note.locked),
        ]
        if note.locked {
            payload["message"] = .string(
                "This note is locked; its contents are encrypted and are not served. Unlock it in Notetaker."
            )
            return .object(payload)
        }
        payload["frontmatter"] = .object(note.frontmatter.mapValues { .string($0) })
        payload["content"] = .string(note.body ?? "")
        return .object(payload)
    }

    /// Cheap frontmatter peek, for listing flags only — anything that
    /// serves a BODY parses the whole file instead (see `VaultSearch`).
    func isLocked(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096),
              let text = String(data: head, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                return false
            }
            if trimmed == "locked: true" {
                return true
            }
        }
        return false
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

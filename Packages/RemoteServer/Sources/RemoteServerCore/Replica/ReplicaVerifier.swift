import Foundation

/// Reads and checks the replica directory. Pure reads: nothing here writes.
/// A single pass reads each manifest file once, hashes the bytes it read, and
/// keeps those same bytes for indexing, so what is verified is what is indexed.
struct ReplicaVerifier {
    struct Note {
        let id: String
        let contents: String
        let modifiedAt: Date?
    }

    struct Verified {
        let manifest: ReplicaManifest
        let notes: [Note]
    }

    enum Outcome {
        case empty
        case disabled
        /// `reason` is path-free by design (it reaches the audit log).
        case inconsistent(reason: String)
        case ok(Verified)
    }

    let config: RemoteConfig

    func verify() -> Outcome {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: config.disabledMarkerURL.path) {
            return .disabled
        }
        guard let manifestData = try? Data(contentsOf: config.manifestURL) else { return .empty }
        guard let manifest = try? ReplicaManifest.decode(manifestData) else {
            return .inconsistent(reason: "manifest undecodable")
        }
        if manifest.disabled {
            return .disabled
        }
        guard manifest.schemaVersion == ReplicaManifest.supportedSchemaVersion else {
            return .inconsistent(reason: "unsupported manifest schema")
        }
        guard manifest.noteCount == manifest.files.count else {
            return .inconsistent(reason: "note count mismatch")
        }

        var notes: [Note] = []
        var listed = Set<String>()
        for entry in manifest.files {
            guard Self.isSafe(relativePath: entry.path), listed.insert(entry.path).inserted else {
                return .inconsistent(reason: "unsafe or duplicate path in manifest")
            }
            let url = config.vaultDir.appendingPathComponent(entry.path)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard let attributes, attributes[.type] as? FileAttributeType == .typeRegular else {
                return .inconsistent(reason: "listed file missing or not a regular file")
            }
            guard let data = try? Data(contentsOf: url) else {
                return .inconsistent(reason: "listed file unreadable")
            }
            guard data.count == entry.bytes, Hashing.sha256Hex(data) == entry.sha256.lowercased() else {
                return .inconsistent(reason: "file digest mismatch")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .inconsistent(reason: "listed file is not UTF-8")
            }
            notes.append(Note(id: entry.path, contents: text, modifiedAt: attributes[.modificationDate] as? Date))
        }

        if let extra = Self.firstUnlistedMarkdown(in: config.vaultDir, listed: listed) {
            _ = extra
            return .inconsistent(reason: "markdown file not in manifest")
        }
        guard ReplicaManifest.digest(of: manifest.files) == manifest.filesDigest.lowercased() else {
            return .inconsistent(reason: "files digest mismatch")
        }
        return .ok(Verified(manifest: manifest, notes: notes))
    }

    static func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              !relativePath.contains("\\")
        else { return false }
        return !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }

    /// Any `.md` (hidden ones included) under `vault/` that the manifest does not list.
    static func firstUnlistedMarkdown(in vault: URL, listed: Set<String>) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: vault, includingPropertiesForKeys: nil, options: []
        ) else { return nil }
        let prefix = vault.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            if !listed.contains(relative) {
                return relative
            }
        }
        return nil
    }
}

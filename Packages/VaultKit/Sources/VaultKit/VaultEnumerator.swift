import Foundation

/// One-shot snapshot of the vault tree straight from the filesystem.
/// Complements MetadataQueryObserver (ubiquity-scope only) for initial scans
/// and index rebuilds, and works on any root (tests use temp dirs).
///
/// Tolerant of external mutation: items that vanish or lose attributes
/// mid-scan are skipped, never fatal — Obsidian/Files.app may be editing the
/// same folder at any moment.
public enum VaultEnumerator {
    public static func snapshot(of root: URL) -> [VaultItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true } // skip unreadable entries, keep walking
        ) else {
            return []
        }

        var items: [VaultItem] = []
        for case let url as URL in enumerator {
            // Attributes can fail if the item vanished mid-scan — skip it.
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            items.append(VaultItem(
                url: url,
                relativePath: VaultPath.relativePath(of: url, in: root),
                isDirectory: values.isDirectory ?? false,
                modificationDate: values.contentModificationDate,
                downloadState: .current
            ))
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }
}

import Foundation
import VaultKit

/// User-registered vaults. "icloud" is the built-in default (the ubiquity
/// container); custom entries point at folders the user picked (e.g. an
/// existing Obsidian vault), persisted as bookmarks. macOS-only UI — iOS
/// stays on the iCloud vault.
enum VaultRegistry {
    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var bookmark: Data
    }

    static let iCloudId = "icloud"
    static let activeKey = "activeVault"
    private static let listKey = "customVaults"

    static var entries: [Entry] {
        get {
            UserDefaults.standard.data(forKey: listKey)
                .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: listKey)
        }
    }

    static var activeId: String {
        UserDefaults.standard.string(forKey: activeKey) ?? iCloudId
    }

    @discardableResult
    static func add(url: URL) -> Entry? {
        guard let data = try? VaultBookmark.make(for: url) else { return nil }
        let entry = Entry(id: UUID().uuidString, name: url.lastPathComponent, bookmark: data)
        entries = entries.filter { $0.name != entry.name } + [entry]
        return entry
    }

    static func remove(id: String) {
        entries = entries.filter { $0.id != id }
    }

    /// The active vault's root when it is a custom folder (nil = iCloud).
    /// Refreshes stale bookmarks and opens the security scope.
    static func activeCustomRoot() -> URL? {
        let active = activeId
        guard active != iCloudId,
              var entry = entries.first(where: { $0.id == active }),
              let resolved = try? VaultBookmark.resolve(entry.bookmark)
        else { return nil }
        if resolved.isStale, let fresh = try? VaultBookmark.make(for: resolved.url) {
            entry.bookmark = fresh
            entries = entries.map { $0.id == entry.id ? entry : $0 }
        }
        _ = resolved.url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return resolved.url
    }
}

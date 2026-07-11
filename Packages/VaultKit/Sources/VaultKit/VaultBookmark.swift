import Foundation

/// Persistence for user-chosen vault roots outside the ubiquity container
/// (e.g. pointing Notetaker at an existing Obsidian vault folder).
/// Security-scoped where the sandbox provides it, with a plain-bookmark
/// fallback so unsandboxed contexts (tests, CLI tools) keep working.
public enum VaultBookmark {
    /// Mints bookmark data for a folder the user picked in an open panel.
    public static func make(for url: URL) throws -> Data {
        #if os(macOS)
            do {
                return try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                // Unsandboxed processes can't mint scoped bookmarks.
                return try url.bookmarkData()
            }
        #else
            return try url.bookmarkData()
        #endif
    }

    /// Resolves bookmark data; `isStale` means the caller should re-mint
    /// via `make(for:)` and persist the fresh data.
    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                url = try URL(
                    resolvingBookmarkData: data,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            return (url, isStale)
        #else
            let url = try URL(
                resolvingBookmarkData: data,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        #endif
    }

    /// Runs `body` inside start/stopAccessingSecurityScopedResource.
    /// startAccessing returns false outside a sandbox — that's fine, access
    /// simply isn't gated there.
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }
}

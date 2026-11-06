import Foundation

/// One file or folder inside the vault, as observed by enumeration.
public struct VaultItem: Identifiable, Equatable, Hashable, Sendable {
    /// iCloud download state, mapped from NSMetadataUbiquitousItemDownloadingStatus*.
    public enum DownloadState: String, Sendable {
        /// Placeholder only — content not on this device.
        case notDownloaded
        /// Present locally, but a newer version exists in iCloud.
        case downloaded
        /// Local copy is the latest known version.
        case current
    }

    public let url: URL
    public let relativePath: String
    public let isDirectory: Bool
    public let modificationDate: Date?
    public let downloadState: DownloadState
    public let isUploading: Bool
    public let hasUnresolvedConflicts: Bool

    public var id: String {
        relativePath
    }

    public init(
        url: URL,
        relativePath: String,
        isDirectory: Bool,
        modificationDate: Date?,
        downloadState: DownloadState,
        isUploading: Bool = false,
        hasUnresolvedConflicts: Bool = false
    ) {
        self.url = url
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.downloadState = downloadState
        self.isUploading = isUploading
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
    }
}

public extension VaultItem.DownloadState {
    /// Maps a raw NSMetadataUbiquitousItemDownloadingStatus value; items with
    /// no ubiquitous status (plain local files) count as current.
    init(ubiquitousStatus: String?) {
        switch ubiquitousStatus {
        case NSMetadataUbiquitousItemDownloadingStatusNotDownloaded:
            self = .notDownloaded
        case NSMetadataUbiquitousItemDownloadingStatusDownloaded:
            self = .downloaded
        default:
            self = .current
        }
    }
}

public enum VaultPath {
    /// True when any folder component of `relativePath` — every component EXCEPT the last —
    /// starts with ".", e.g. `.trash/Note.md` or `Work/.obsidian/x.md`. The last component is
    /// left alone on purpose, so iCloud placeholder names (`.Note.md.icloud`) are unaffected.
    public static func isInsideHiddenFolder(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
    }

    /// True for entries the vault listing must never surface: anything under a hidden folder,
    /// and a hidden folder itself (`.trash`, `.obsidian`). `VaultEnumerator` gets the same
    /// answer from `.skipsHiddenFiles`; `MetadataQueryObserver` has no such option, so it asks
    /// here.
    public static func isHiddenTreeEntry(_ relativePath: String, isDirectory: Bool) -> Bool {
        if isInsideHiddenFolder(relativePath) {
            return true
        }
        return isDirectory && (relativePath.split(separator: "/").last?.hasPrefix(".") ?? false)
    }

    /// True for the vault's Daily folder and anything inside it (`Daily`, `Daily/2026`). The
    /// notes there are named by date, so the Notes list shows them newest first. The folder name
    /// is the one `NotesModel.openDailyNote` creates; the comparison ignores case because the
    /// vault lives on a case-insensitive filesystem.
    public static func isDailyFolder(_ relativeFolder: String) -> Bool {
        relativeFolder.split(separator: "/").first?.lowercased() == "daily"
    }

    /// Path of `url` relative to `root`, "" when url IS the root.
    public static func relativePath(of url: URL, in root: URL) -> String {
        relativePath(of: url, inRootComponents: components(of: root))
    }

    /// `root`'s standardized path components, for callers that resolve many URLs against
    /// one root (a vault snapshot is ~2000 items; re-standardizing the root per item showed
    /// up as a third of the main thread's time on the phone).
    public static func components(of root: URL) -> [String] {
        root.standardizedFileURL.pathComponents
    }

    public static func relativePath(of url: URL, inRootComponents rootComponents: [String]) -> String {
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count >= rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return url.standardizedFileURL.path
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

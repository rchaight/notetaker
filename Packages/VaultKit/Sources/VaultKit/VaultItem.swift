import Foundation

/// One file or folder inside the vault, as observed by enumeration.
public struct VaultItem: Identifiable, Equatable, Sendable {
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
    /// Path of `url` relative to `root`, "" when url IS the root.
    public static func relativePath(of url: URL, in root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count >= rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return url.standardizedFileURL.path
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

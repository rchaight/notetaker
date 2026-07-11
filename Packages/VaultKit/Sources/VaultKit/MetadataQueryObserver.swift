import Foundation

/// Live enumeration of the vault via NSMetadataQuery over the ubiquitous
/// Documents scope. Emits a full snapshot after initial gathering and after
/// every update batch. NSMetadataQuery is runloop-bound, so this type is
/// main-actor confined.
@MainActor
public final class MetadataQueryObserver {
    private let root: URL
    private let query = NSMetadataQuery()
    private var notificationTokens: [NSObjectProtocol] = []
    private var continuation: AsyncStream<[VaultItem]>.Continuation?

    public init(root: URL) {
        self.root = root
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
    }

    /// Starts the query and streams snapshots. One consumer per observer.
    public func snapshots() -> AsyncStream<[VaultItem]> {
        AsyncStream { continuation in
            self.continuation = continuation
            let center = NotificationCenter.default
            for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                         NSNotification.Name.NSMetadataQueryDidUpdate] {
                let token = center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.emitSnapshot()
                    }
                }
                notificationTokens.append(token)
            }
            query.start()
        }
    }

    public func stop() {
        query.stop()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private func emitSnapshot() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var items: [VaultItem] = []
        for case let result as NSMetadataItem in query.results {
            guard let url = result.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = result.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let uploading = result.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool ?? false
            let conflicted = result
                .value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool ?? false
            let modified = result.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            let contentType = result.value(forAttribute: NSMetadataItemContentTypeKey) as? String

            items.append(VaultItem(
                url: url,
                relativePath: VaultPath.relativePath(of: url, in: root),
                isDirectory: contentType == "public.folder" || url.hasDirectoryPath,
                modificationDate: modified,
                downloadState: VaultItem.DownloadState(ubiquitousStatus: status),
                isUploading: uploading,
                hasUnresolvedConflicts: conflicted
            ))
        }
        continuation?.yield(items)
    }
}

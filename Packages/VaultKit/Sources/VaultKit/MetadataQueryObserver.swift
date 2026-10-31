import Foundation

/// Live enumeration of the vault via NSMetadataQuery over the ubiquitous
/// Documents scope. Emits a full snapshot after initial gathering and after
/// update bursts.
///
/// The query's notifications and the snapshot build run on a private serial queue,
/// never the main thread: iCloud posts updates continuously while a container with
/// ~2000 notes syncs, and rebuilding the whole snapshot (six metadata lookups per
/// item) on the main thread for each one starved the UI on the iPhone (a profile
/// showed the main thread 76% busy, a third of it in this loop). Update bursts are
/// coalesced into one trailing snapshot, and the stream keeps only the newest
/// snapshot so a slow consumer never works through a backlog of stale ones.
@MainActor
public final class MetadataQueryObserver {
    private let worker: Worker

    public init(root: URL) {
        worker = Worker(root: root)
    }

    /// Starts the query and streams snapshots. One consumer per observer.
    public func snapshots() -> AsyncStream<[VaultItem]> {
        worker.snapshots()
    }

    public func stop() {
        worker.stop()
    }
}

/// All query state. Mutable state is touched either on `queue` (the query's operation
/// queue) or under `lock`; the query is started and stopped from the main thread, which
/// NSMetadataQuery requires (it is runloop-bound).
private final class Worker: @unchecked Sendable {
    /// Quiet period after the first update of a burst before the snapshot is built.
    static let updateDelay: DispatchTimeInterval = .milliseconds(400)

    private let rootComponents: [String]
    private let query = NSMetadataQuery()
    private let queue = DispatchQueue(label: "VaultKit.MetadataQueryObserver", qos: .userInitiated)
    private let operationQueue = OperationQueue()

    private let lock = NSLock()
    private var notificationTokens: [NSObjectProtocol] = []
    private var continuation: AsyncStream<[VaultItem]>.Continuation?
    private var stopped = false

    /// Only touched on `queue`.
    private var emitScheduled = false

    init(root: URL) {
        rootComponents = VaultPath.components(of: root)
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
        query.operationQueue = operationQueue
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
    }

    func snapshots() -> AsyncStream<[VaultItem]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let center = NotificationCenter.default
            let gathered = center.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: operationQueue
            ) { [weak self] _ in
                self?.emitSnapshot()
            }
            let updated = center.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: query, queue: operationQueue
            ) { [weak self] _ in
                self?.scheduleSnapshot()
            }
            lock.lock()
            notificationTokens = [gathered, updated]
            lock.unlock()
            query.start()
        }
    }

    func stop() {
        query.stop()
        lock.lock()
        stopped = true
        let tokens = notificationTokens
        notificationTokens.removeAll()
        let finished = continuation
        continuation = nil
        lock.unlock()
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        finished?.finish()
    }

    /// Runs on `queue`. The first update of a burst arms one trailing snapshot; the rest
    /// of the burst rides on it.
    private func scheduleSnapshot() {
        guard !emitScheduled else { return }
        emitScheduled = true
        queue.asyncAfter(deadline: .now() + Self.updateDelay) { [weak self] in
            guard let self else { return }
            emitScheduled = false
            emitSnapshot()
        }
    }

    /// Runs on `queue`.
    private func emitSnapshot() {
        lock.lock()
        let target = stopped ? nil : continuation
        lock.unlock()
        guard let target else { return }

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
            let isDirectory = contentType == "public.folder" || url.hasDirectoryPath
            let relativePath = VaultPath.relativePath(of: url, inRootComponents: rootComponents)
            // App-owned per-folder TOC: never a note (see VaultFileStore.isIndexFile).
            // Still a valid trigger — this snapshot is dropped, not the change event.
            if !isDirectory, VaultFileStore.isIndexFile(relativePath) {
                continue
            }

            items.append(VaultItem(
                url: url,
                relativePath: relativePath,
                isDirectory: isDirectory,
                modificationDate: modified,
                downloadState: VaultItem.DownloadState(ubiquitousStatus: status),
                isUploading: uploading,
                hasUnresolvedConflicts: conflicted
            ))
        }
        target.yield(items)
    }
}

import Foundation

/// Presents the vault root directory and streams the URL of anything that
/// changes beneath it — edits by the iCloud daemon, Finder, or other apps.
/// Complements MetadataQueryObserver with immediate, local signals.
///
/// @unchecked Sendable: all stored properties are immutable after init and
/// AsyncStream.Continuation is thread-safe.
public final class VaultPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue

    /// Raw, un-debounced change pings. Feed through `Debouncer` before
    /// triggering reindexing work.
    public let changes: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation
    private let root: URL

    public init(root: URL) {
        self.root = root
        presentedItemURL = root
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        (changes, continuation) = AsyncStream.makeStream()
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    public func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        continuation.finish()
    }

    // MARK: - NSFilePresenter

    public func presentedItemDidChange() {
        continuation.yield(root)
    }

    public func presentedSubitemDidChange(at url: URL) {
        continuation.yield(url)
    }

    public func presentedSubitemDidAppear(at url: URL) {
        continuation.yield(url)
    }

    public func presentedSubitem(at _: URL, didMoveTo newURL: URL) {
        continuation.yield(newURL)
    }
}

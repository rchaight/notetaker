#if os(macOS)
    import Foundation

    /// DispatchSource-based watcher over every directory in the vault tree —
    /// the macOS belt-and-suspenders complement to NSFilePresenter and
    /// NSMetadataQuery, catching structural changes (create/rename/delete)
    /// immediately even when no coordinated writer is involved.
    ///
    /// @unchecked Sendable: `sources` is only mutated on `queue`; the
    /// continuation is thread-safe.
    public final class DirectoryWatcher: @unchecked Sendable {
        /// Fires with the directory URL whose entries changed.
        public let events: AsyncStream<URL>

        private let continuation: AsyncStream<URL>.Continuation
        private let root: URL
        private let queue = DispatchQueue(label: "vaultkit.directory-watcher")
        private var sources: [URL: DispatchSourceFileSystemObject] = [:]

        public init(root: URL) {
            self.root = root
            (events, continuation) = AsyncStream.makeStream()
            queue.async { self.rebuildWatchSet() }
        }

        public func stop() {
            queue.async {
                for source in self.sources.values {
                    source.cancel()
                }
                self.sources.removeAll()
                self.continuation.finish()
            }
        }

        /// Re-walks the tree and watches any directories that appeared;
        /// called automatically after every event.
        private func rebuildWatchSet() {
            var directories: Set<URL> = [root.standardizedFileURL]
            for item in VaultEnumerator.snapshot(of: root) where item.isDirectory {
                directories.insert(item.url.standardizedFileURL)
            }

            for gone in Set(sources.keys).subtracting(directories) {
                sources[gone]?.cancel()
                sources[gone] = nil
            }

            for url in directories where sources[url] == nil {
                let descriptor = open(url.path, O_EVTONLY)
                guard descriptor >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .rename, .delete],
                    queue: queue
                )
                source.setEventHandler { [weak self] in
                    self?.continuation.yield(url)
                    self?.rebuildWatchSet()
                }
                source.setCancelHandler {
                    close(descriptor)
                }
                sources[url] = source
                source.resume()
            }
        }
    }
#endif

import Foundation

/// Coordinated file I/O for vault documents. Every operation goes through
/// NSFileCoordinator so it is safe against the iCloud daemon, Finder, and
/// other processes touching the same files.
public struct VaultFileStore: Sendable {
    public init() {}

    /// Coordinated read; blocks (off-executor) until a placeholder finishes
    /// downloading, per NSFileCoordinator semantics.
    public func readString(at url: URL) async throws -> String {
        try await coordinatedRead(at: url) { actualURL in
            try String(contentsOf: actualURL, encoding: .utf8)
        }
    }

    /// Coordinated atomic write, creating intermediate folders as needed.
    public func writeString(_ contents: String, to url: URL) async throws {
        try await coordinatedWrite(at: url, options: .forReplacing) { actualURL in
            try FileManager.default.createDirectory(
                at: actualURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: actualURL, atomically: true, encoding: .utf8)
        }
    }

    public func delete(at url: URL) async throws {
        try await coordinatedWrite(at: url, options: .forDeleting) { actualURL in
            try FileManager.default.removeItem(at: actualURL)
        }
    }

    public func move(from source: URL, to destination: URL) async throws {
        try await coordinatedWrite(at: source, options: .forMoving) { actualSource in
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: actualSource, to: destination)
        }
    }

    /// Coordinated folder creation (rename/move/delete of folders reuse
    /// `move`/`delete` — NSFileCoordinator and FileManager handle directories).
    public func createFolder(at url: URL) async throws {
        try await coordinatedWrite(at: url, options: []) { actualURL in
            try FileManager.default.createDirectory(at: actualURL, withIntermediateDirectories: true)
        }
    }

    /// Kicks off download of an iCloud placeholder and returns immediately;
    /// progress surfaces through MetadataQueryObserver snapshots.
    public func startDownloading(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // MARK: - Coordination plumbing

    private func coordinatedRead<T: Sendable>(
        at url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        accessor: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<T, Error> = .failure(CocoaError(.fileReadUnknown))
            coordinator.coordinate(readingItemAt: url, options: options, error: &coordinationError) { actualURL in
                result = Result { try accessor(actualURL) }
            }
            if let coordinationError {
                throw coordinationError
            }
            return try result.get()
        }.value
    }

    private func coordinatedWrite(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        accessor: @escaping @Sendable (URL) throws -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<Void, Error> = .success(())
            coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { actualURL in
                result = Result { try accessor(actualURL) }
            }
            if let coordinationError {
                throw coordinationError
            }
            return try result.get()
        }.value
    }
}

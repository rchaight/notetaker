import Foundation

public enum VaultError: Error, Equatable, Sendable {
    /// iCloud Drive unavailable: not signed in, iCloud Drive off, or the
    /// container is not provisioned for this build.
    case iCloudUnavailable
}

public enum UbiquityContainer {
    /// The container's deterministic on-disk location once it has ever been
    /// materialized — lets the UI render instantly while the (potentially
    /// slow, cold) ubiquity resolution confirms in the background.
    public static func wellKnownDocumentsURL(containerIdentifier: String) -> URL? {
        #if os(macOS)
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
                .appendingPathComponent(
                    containerIdentifier.replacingOccurrences(of: ".", with: "~"),
                    isDirectory: true
                )
                .appendingPathComponent("Documents", isDirectory: true)
            return FileManager.default.fileExists(atPath: path.path) ? path : nil
        #else
            _ = containerIdentifier
            return nil // iOS containers live inside app group paths
        #endif
    }

    /// Resolves the app's ubiquity `Documents/` directory, creating it if
    /// needed. `FileManager.url(forUbiquityContainerIdentifier:)` can block,
    /// so it runs off the caller's executor.
    public static func documentsURL(containerIdentifier: String? = nil) async throws -> URL {
        let container = try await Task.detached(priority: .userInitiated) {
            guard let url = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
                throw VaultError.iCloudUnavailable
            }
            return url
        }.value
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }
}

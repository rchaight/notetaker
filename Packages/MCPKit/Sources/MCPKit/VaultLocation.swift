import Foundation

/// Where the vault and its derived index live. Resolved WITHOUT the app
/// running — the server is a separate unsandboxed process that Claude
/// spawns, so it reconstructs the same paths `VaultIndexService` uses.
public struct VaultLocation: Sendable, Equatable {
    /// How the root was found — surfaced in `vault_overview` so a wrong
    /// vault is obvious rather than mysterious.
    public enum Origin: String, Sendable {
        case argument
        case registeredVault
        case iCloud
    }

    public let root: URL
    /// nil when no index file can belong to this root (e.g. an ad-hoc
    /// `--vault` folder the app has never indexed) — tools then scan.
    public let indexPath: String?
    public let origin: Origin

    public init(root: URL, indexPath: String?, origin: Origin) {
        self.root = root
        self.indexPath = indexPath
        self.origin = origin
    }
}

/// Resolution order per spec: `--vault <path>` → the app's active vault in
/// its UserDefaults suite → the literal iCloud Drive container path.
public enum VaultLocator {
    /// The app is unsandboxed, so its preference domain is readable from
    /// any process on the machine.
    public static let defaultsSuiteName = "com.rchaight.notetaker"

    /// The app's preference domain. Bundled inside Notetaker.app, this
    /// process reports the app's own bundle identifier, and asking for it as
    /// a *suite* is both noisy and unreliable — `.standard` already is that
    /// domain. Outside the bundle the suite is the only way in.
    public static func appDefaults() -> UserDefaults? {
        if Bundle.main.bundleIdentifier == defaultsSuiteName {
            return .standard
        }
        return UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    static let iCloudVaultId = "icloud"
    static let activeVaultKey = "activeVault"
    static let customVaultsKey = "customVaults"

    public enum LocatorError: Error, CustomStringConvertible {
        case missingArgumentValue(String)
        case rootNotFound(URL)

        public var description: String {
            switch self {
            case let .missingArgumentValue(flag):
                "\(flag) needs a path"
            case let .rootNotFound(url):
                """
                vault folder not found: \(url.path)
                Open Notetaker once to create it, or pass --vault <path>.
                """
            }
        }
    }

    /// A vault the app registered (custom folder picked by the user).
    struct RegisteredVault: Decodable {
        let id: String
        let name: String
        let bookmark: Data
    }

    public static func resolve(
        arguments: [String],
        defaults: UserDefaults? = appDefaults(),
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> VaultLocation {
        let indexDirectory = (applicationSupport ?? defaultApplicationSupport(fileManager))
            .appendingPathComponent("Index", isDirectory: true)
        let registered = registeredVaults(defaults)

        if let explicit = try value(of: "--vault", in: arguments) {
            let root = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
                .standardizedFileURL
            try requireDirectory(root, fileManager)
            // Only claim an index when the folder really is a vault the app
            // indexes; otherwise scan rather than answer from a stranger's DB.
            let matchedId = registered.first { resolveBookmark($0.bookmark)?.standardizedFileURL == root }?.id
            let indexName: String? = if let matchedId {
                "index-\(matchedId).sqlite"
            } else if root == iCloudVaultRoot(fileManager).standardizedFileURL {
                "index.sqlite"
            } else {
                nil
            }
            return try VaultLocation(
                root: root,
                indexPath: indexPath(named: indexName, in: indexDirectory, arguments: arguments),
                origin: .argument
            )
        }

        let activeId = defaults?.string(forKey: activeVaultKey) ?? iCloudVaultId
        if activeId != iCloudVaultId,
           let entry = registered.first(where: { $0.id == activeId }),
           let root = resolveBookmark(entry.bookmark),
           isDirectory(root, fileManager) {
            return try VaultLocation(
                root: root.standardizedFileURL,
                indexPath: indexPath(
                    named: "index-\(activeId).sqlite", in: indexDirectory, arguments: arguments
                ),
                origin: .registeredVault
            )
        }

        let root = iCloudVaultRoot(fileManager)
        try requireDirectory(root, fileManager)
        return try VaultLocation(
            root: root.standardizedFileURL,
            indexPath: indexPath(named: "index.sqlite", in: indexDirectory, arguments: arguments),
            origin: .iCloud
        )
    }

    /// `--index <path>` overrides the derived location (tests, and a hedge
    /// against the app's naming ever drifting).
    private static func indexPath(
        named name: String?, in directory: URL, arguments: [String]
    ) throws -> String? {
        if let override = try value(of: "--index", in: arguments) {
            return (override as NSString).expandingTildeInPath
        }
        return name.map { directory.appendingPathComponent($0).path }
    }

    static func value(of flag: String, in arguments: [String]) throws -> String? {
        for (offset, argument) in arguments.enumerated() {
            if argument == flag {
                guard offset + 1 < arguments.count else { throw LocatorError.missingArgumentValue(flag) }
                return arguments[offset + 1]
            }
            if argument.hasPrefix(flag + "=") {
                let value = String(argument.dropFirst(flag.count + 1))
                guard !value.isEmpty else { throw LocatorError.missingArgumentValue(flag) }
                return value
            }
        }
        return nil
    }

    static func iCloudVaultRoot(_ fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .appendingPathComponent("iCloud~com~rchaight~notetaker", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    private static func defaultApplicationSupport(_ fileManager: FileManager) -> URL {
        (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func registeredVaults(_ defaults: UserDefaults?) -> [RegisteredVault] {
        guard let data = defaults?.data(forKey: customVaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RegisteredVault].self, from: data)) ?? []
    }

    /// The app mints plain bookmarks when unsandboxed and scoped ones when
    /// not; try both, and don't fail the whole launch over a stale entry.
    private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &isStale
        ) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        return try? URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func requireDirectory(_ url: URL, _ fileManager: FileManager) throws {
        guard isDirectory(url, fileManager) else { throw LocatorError.rootNotFound(url) }
    }
}

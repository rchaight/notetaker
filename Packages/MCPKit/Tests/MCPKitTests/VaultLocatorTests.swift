import Foundation
@testable import MCPKit
import Testing

/// The server has to find the same vault and the same index file the app
/// uses, with nothing running to ask.
struct VaultLocatorTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpkit-locate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func emptyDefaults() -> UserDefaults {
        let suite = "MCPKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func vaultArgumentWins() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let location = try VaultLocator.resolve(
            arguments: ["--vault", folder.path],
            defaults: emptyDefaults(),
            applicationSupport: support
        )
        #expect(location.origin == .argument)
        #expect(location.root == folder.standardizedFileURL)
        // An unregistered folder has no index of its own — scan, don't guess.
        #expect(location.indexPath == nil)
    }

    @Test func vaultArgumentAcceptsEqualsForm() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let location = try VaultLocator.resolve(
            arguments: ["--vault=\(folder.path)"], defaults: emptyDefaults(),
            applicationSupport: temporaryDirectory()
        )
        #expect(location.root == folder.standardizedFileURL)
    }

    @Test func indexArgumentOverridesTheDerivedPath() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let location = try VaultLocator.resolve(
            arguments: ["--vault", folder.path, "--index", "/tmp/custom.sqlite"],
            defaults: emptyDefaults(),
            applicationSupport: temporaryDirectory()
        )
        #expect(location.indexPath == "/tmp/custom.sqlite")
    }

    @Test func missingVaultFolderIsAClearError() throws {
        #expect(throws: VaultLocator.LocatorError.self) {
            _ = try VaultLocator.resolve(
                arguments: ["--vault", "/nowhere/at/all"], defaults: emptyDefaults(),
                applicationSupport: temporaryDirectory()
            )
        }
    }

    @Test func flagWithoutAValueIsAnError() throws {
        #expect(throws: VaultLocator.LocatorError.self) {
            _ = try VaultLocator.value(of: "--vault", in: ["--vault"])
        }
    }

    @Test func registeredVaultFromTheAppsDefaults() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        // Exactly the shape VaultRegistry persists.
        let entry: [String: Any] = try [
            "id": "vault-1",
            "name": folder.lastPathComponent,
            "bookmark": folder.bookmarkData().base64EncodedString(),
        ]
        let defaults = emptyDefaults()
        try defaults.set(JSONSerialization.data(withJSONObject: [entry]), forKey: "customVaults")
        defaults.set("vault-1", forKey: "activeVault")

        let location = try VaultLocator.resolve(
            arguments: [], defaults: defaults, applicationSupport: support
        )
        #expect(location.origin == .registeredVault)
        #expect(location.root == folder.standardizedFileURL)
        #expect(location.indexPath == support.appendingPathComponent("Index/index-vault-1.sqlite").path)
    }

    @Test func fallsBackToTheICloudContainer() throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let iCloudRoot = VaultLocator.iCloudVaultRoot()

        // The literal container path is a machine fact, not a test fixture —
        // assert on the derived index name, and only assert the root when
        // this machine actually has the container.
        guard FileManager.default.fileExists(atPath: iCloudRoot.path) else {
            #expect(throws: VaultLocator.LocatorError.self) {
                _ = try VaultLocator.resolve(
                    arguments: [], defaults: emptyDefaults(), applicationSupport: support
                )
            }
            return
        }
        let location = try VaultLocator.resolve(
            arguments: [], defaults: emptyDefaults(), applicationSupport: support
        )
        #expect(location.origin == .iCloud)
        #expect(location.root == iCloudRoot.standardizedFileURL)
        #expect(location.indexPath == support.appendingPathComponent("Index/index.sqlite").path)
    }
}

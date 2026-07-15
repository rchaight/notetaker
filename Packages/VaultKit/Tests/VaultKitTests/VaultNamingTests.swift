import Foundation
import Testing
@testable import VaultKit

struct VaultNamingTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func skipsFilesOnDisk() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "x".write(to: folder.appendingPathComponent("Untitled.md"), atomically: true, encoding: .utf8)
        #expect(VaultNaming.uniqueFileName(base: "Untitled", ext: "md", in: folder) == "Untitled 2.md")
    }

    @Test func skipsICloudPlaceholders() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The note only exists remotely: local disk has just the placeholder.
        try "stub".write(
            to: folder.appendingPathComponent(".Untitled.md.icloud"),
            atomically: true, encoding: .utf8
        )
        #expect(VaultNaming.isTaken(folder.appendingPathComponent("Untitled.md")))
        #expect(VaultNaming.uniqueFileName(base: "Untitled", ext: "md", in: folder) == "Untitled 2.md")
    }

    @Test func honorsReservedNamesAndCounts() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "x".write(to: folder.appendingPathComponent("Note 2.md"), atomically: true, encoding: .utf8)
        let name = VaultNaming.uniqueFileName(
            base: "Note", ext: "md", in: folder, reserved: ["Note.md"]
        )
        #expect(name == "Note 3.md")
    }

    @Test func freeNameStaysUntouched() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(VaultNaming.uniqueFileName(base: "Fresh", ext: "md", in: folder) == "Fresh.md")
    }
}
